defmodule FLAME.K8sBackend do
  @moduledoc """
  The `FLAME.Backend` using [Kubernetes](https://kubernetes.io/) system.

  This backend creates FlameRunner CRD resources which are then reconciled
  by the flame-k8s-controller to create actual runner pods.

  ## Configuration

  Configure the flame backend in your application:

      # config.exs
      if config_env() == :prod do
        config :flame, :backend, FLAME.K8sBackend
        config :flame, FLAME.K8sBackend,
          log: :debug,
          boot_timeout: 30_000
      end

  ## How it works

  1. Parent application calls FLAME.cast/3 or FLAME.call/3
  2. Backend creates a FlameRunner CRD in Kubernetes
  3. flame-k8s-controller detects the FlameRunner and creates a Pod
  4. Pod starts and connects back to parent via distributed Erlang
  5. Work is executed on the runner
  6. Runner terminates and FlameRunner/Pod are cleaned up
  """
  @behaviour FLAME.Backend

  alias FLAME.K8sBackend

  require Logger

  # Implements FLAME.Backend behaviour
  # @behaviour declaration omitted to avoid compile-time dependency

  defstruct boot_timeout: nil,
            conn: nil,
            env: %{},
            log: false,
            parent_ref: nil,
            remote_terminator_pid: nil,
            runner_node_name: nil,
            runner_pod_ip: nil,
            runner_pod_name: nil,
            runner_namespace: nil

  @valid_opts ~w(boot_timeout log)a
  @required_config ~w()a

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    conf = Application.get_env(:flame, __MODULE__) || []

    default = %K8sBackend{
      boot_timeout: 30_000
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    state = struct(default, provided_opts)

    for key <- @required_config do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    parent_ref = make_ref()

    # Encode parent info - will be decoded by FLAME library at runtime
    encoded_parent =
      %{
        ref: parent_ref,
        pid: self(),
        backend: __MODULE__
      }
      |> :erlang.term_to_binary()
      |> Base.encode64()

    new_env =
      Map.merge(
        %{FLAME_PARENT: encoded_parent},
        state.env
      )

    # Get Kubernetes connection
    conn = get_k8s_connection()

    initial_state =
      struct(state,
        conn: conn,
        env: new_env,
        parent_ref: parent_ref
      )

    {:ok, initial_state}
  end

  @impl true
  def remote_boot(%K8sBackend{parent_ref: parent_ref} = state) do
    log(state, "Remote Boot - Creating FlameRunner")

    {new_state, req_connect_time} =
      with_elapsed_ms(fn ->
        runner_manifest = build_runner_manifest(state)

        case create_flame_runner(state.conn, runner_manifest) do
          {:ok, runner} ->
            log(state, "FlameRunner created", name: runner["metadata"]["name"])

            # Wait for pod to be created and get IP
            case wait_for_pod_ready(state, runner, state.boot_timeout) do
              {:ok, pod_ip, pod_name} ->
                log(state, "Runner pod ready", pod_ip: pod_ip, pod_name: pod_name)

                struct!(state,
                  runner_pod_ip: pod_ip,
                  runner_pod_name: pod_name,
                  runner_namespace: runner["metadata"]["namespace"]
                )

              {:error, reason} ->
                Logger.error("Failed to get pod ready: #{inspect(reason)}")
                exit(:timeout)
            end

          {:error, reason} ->
            Logger.error("Failed to create FlameRunner: #{inspect(reason)}")
            exit(:timeout)
        end
      end)

    remaining_connect_window = state.boot_timeout - req_connect_time
    runner_node_name = :"#{get_node_base()}@#{new_state.runner_pod_ip}"

    log(state, "Waiting for Remote UP", remaining_ms: remaining_connect_window)

    case loop_until_ok(fn -> Node.connect(runner_node_name) end, remaining_connect_window) do
      {:ok, _} -> log(state, "Connected to runner node")
      _ -> exit(:timeout)
    end

    remote_terminator_pid =
      receive do
        {^parent_ref, {:remote_up, remote_terminator_pid}} ->
          remote_terminator_pid
      after
        remaining_connect_window ->
          Logger.error("Failed to receive remote_up within #{remaining_connect_window}ms")
          exit(:timeout)
      end

    new_state =
      struct!(new_state,
        remote_terminator_pid: remote_terminator_pid,
        runner_node_name: runner_node_name
      )

    {:ok, remote_terminator_pid, new_state}
  end

  @impl true
  def remote_spawn_monitor(%K8sBackend{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown() do
    # Delete the FlameRunner resource - this will trigger pod cleanup
    namespace = System.get_env("POD_NAMESPACE")
    name = System.get_env("POD_NAME")

    if namespace && name do
      conn = get_k8s_connection()
      delete_flame_runner(conn, namespace, name)
    end

    System.stop()
  end

  @impl true
  def handle_info({:nodedown, down_node}, state) do
    if down_node == state.runner_node_name do
      log(state, "Runner node down", node: down_node)
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, _}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp get_k8s_connection do
    case System.get_env("KUBERNETES_SERVICE_HOST") do
      nil ->
        # Development - use kubeconfig
        {:ok, conn} = K8s.Conn.from_file("~/.kube/config")
        conn

      _host ->
        # Production - use service account
        {:ok, conn} = K8s.Conn.from_service_account()
        conn
    end
  end

  defp get_node_base do
    [node_base | _] = node() |> to_string() |> String.split("@")
    node_base
  end

  defp build_runner_manifest(state) do
    pod_name = System.get_env("POD_NAME") || "unknown-parent"
    pod_namespace = System.get_env("POD_NAMESPACE") || "default"
    pool_ref = System.get_env("FLAME_POOL_CONFIG_REF") || "default-pool"

    parent_uid = get_parent_pod_uid(state.conn, pod_namespace, pod_name)

    image = get_parent_pod_image(state.conn, pod_namespace, pod_name)

    runner_name = generate_runner_name(pod_name)

    %{
      "apiVersion" => "flame.org/v1",
      "kind" => "FlameRunner",
      "metadata" => %{
        "name" => runner_name,
        "namespace" => pod_namespace,
        "labels" => %{
          "flame.org/parent" => pod_name
        }
      },
      "spec" => %{
        "parentRef" => %{
          "name" => pod_name,
          "namespace" => pod_namespace,
          "uid" => parent_uid
        },
        "image" => image,
        "poolRef" => pool_ref,
        "env" => encode_k8s_env(state.env)
      }
    }
  end

  defp get_parent_pod_uid(conn, namespace, name) do
    case K8s.Client.get("v1", "Pod", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, pod} -> get_in(pod, ["metadata", "uid"])
      _ -> nil
    end
  end

  defp get_parent_pod_image(conn, namespace, name) do
    case K8s.Client.get("v1", "Pod", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, pod} ->
        # Get first container image
        get_in(pod, ["spec", "containers", Access.at(0), "image"]) || "busybox:latest"

      _ ->
        "busybox:latest"
    end
  end

  defp generate_runner_name(parent_name) do
    random_suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    parent_prefix = String.slice(parent_name, 0..30)
    "#{parent_prefix}-runner-#{random_suffix}"
  end

  defp create_flame_runner(conn, manifest) do
    operation =
      K8s.Client.create(manifest)
      |> K8s.Client.put_conn(conn)

    case K8s.Client.run(operation) do
      {:ok, runner} -> {:ok, runner}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_pod_ready(state, runner, timeout) do
    namespace = get_in(runner, ["metadata", "namespace"])
    name = get_in(runner, ["metadata", "name"])

    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_pod_ready_loop(state.conn, namespace, name, deadline)
  end

  defp wait_for_pod_ready_loop(conn, namespace, name, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      # Check FlameRunner status
      case K8s.Client.get("flame.org/v1", "FlameRunner", namespace: namespace, name: name)
           |> K8s.Client.put_conn(conn)
           |> K8s.Client.run() do
        {:ok, runner} ->
          status = Map.get(runner, "status", %{})
          pod_ip = Map.get(status, "podIP")
          pod_name = Map.get(status, "podName")
          phase = Map.get(status, "phase")

          cond do
            pod_ip && phase == "Running" ->
              {:ok, pod_ip, pod_name}

            phase == "Failed" ->
              {:error, :pod_failed}

            true ->
              Process.sleep(500)
              wait_for_pod_ready_loop(conn, namespace, name, deadline)
          end

        {:error, _reason} ->
          Process.sleep(500)
          wait_for_pod_ready_loop(conn, namespace, name, deadline)
      end
    end
  end

  defp delete_flame_runner(conn, namespace, name) do
    K8s.Client.delete("flame.org/v1", "FlameRunner", namespace: namespace, name: name)
    |> K8s.Client.put_conn(conn)
    |> K8s.Client.run()
  end

  defp encode_k8s_env(env_map) do
    for {name, value} <- env_map, do: %{"name" => to_string(name), "value" => to_string(value)}
  end

  defp with_elapsed_ms(func) when is_function(func, 0) do
    {micro, result} = :timer.tc(func)
    {result, div(micro, 1000)}
  end

  defp loop_until_ok(func, timeout) do
    task = Task.async(fn -> do_loop(func, func.()) end)
    Task.await(task, timeout)
  rescue
    _ -> {:error, :timeout}
  end

  defp do_loop(_func, {:ok, term}), do: {:ok, term}
  defp do_loop(_func, true), do: {:ok, true}

  defp do_loop(func, _resp) do
    Process.sleep(100)
    do_loop(func, func.())
  rescue
    _ ->
      Process.sleep(100)
      do_loop(func, func.())
  catch
    _ ->
      Process.sleep(100)
      do_loop(func, func.())
  end

  defp log(backend, msg, metadata \\ [])

  defp log(%K8sBackend{log: false}, _, _metadata), do: :ok

  defp log(%K8sBackend{log: level}, msg, metadata) do
    Logger.log(level, msg, metadata)
  end
end

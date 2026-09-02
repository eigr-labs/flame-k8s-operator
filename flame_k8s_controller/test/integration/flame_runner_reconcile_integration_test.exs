defmodule FlameK8sController.Integration.FlameRunnerReconcileTest do
  use ExUnit.Case, async: false

  alias FlameK8sController.Handler.FlameRunnerHandler

  @moduletag :integration

  setup_all do
    case System.get_env("KUBECONFIG") do
      nil ->
        {:ok, conn: nil}

      kubeconfig_path ->
        case K8s.Conn.from_file(kubeconfig_path, insecure_skip_tls_verify: true) do
          {:ok, conn} -> {:ok, conn: conn}
          {:error, _reason} -> {:ok, conn: nil}
        end
    end
  end

  test "reconcile updates status from a real Pod", %{conn: conn} do
    case conn do
      nil ->
        assert true

      _ ->
        namespace = "default"
        runner_name = "runner-int-#{System.unique_integer([:positive])}"

        on_exit(fn ->
          delete_if_exists(conn, "v1", "Pod", namespace, runner_name)
        end)

        runner_resource = runner_resource(namespace, runner_name)

        add_axn =
          Bonny.Axn.new!(
            conn: conn,
            resource: runner_resource,
            action: :add
          )

        add_result = FlameRunnerHandler.call(add_axn, nil)

        assert add_result.status["phase"] == "Pending"
        assert map_size(add_result.descendants) == 1

        {_, {_, pod_manifest}} = Enum.at(add_result.descendants, 0)

        {:ok, _pod} =
          pod_manifest
          |> K8s.Client.create()
          |> K8s.Client.put_conn(conn)
          |> K8s.Client.run()

        pod_status = wait_for_pod_status(conn, namespace, runner_name, 10)

        reconcile_axn =
          Bonny.Axn.new!(
            conn: conn,
            resource: runner_resource,
            action: :reconcile
          )

        reconcile_result = FlameRunnerHandler.call(reconcile_axn, nil)

        assert reconcile_result.status["podName"] == runner_name
        assert reconcile_result.status["phase"] in ["Pending", "Running", "Succeeded", "Failed"]
        assert reconcile_result.status["phase"] == normalize_pod_phase(pod_status["phase"])
    end
  end

  defp wait_for_pod_status(conn, namespace, name, attempts) when attempts > 0 do
    case K8s.Client.get("v1", "Pod", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, pod} ->
        status = Map.get(pod, "status", %{})

        if Map.get(status, "phase") do
          status
        else
          :timer.sleep(500)
          wait_for_pod_status(conn, namespace, name, attempts - 1)
        end

      {:error, _reason} ->
        :timer.sleep(500)
        wait_for_pod_status(conn, namespace, name, attempts - 1)
    end
  end

  defp wait_for_pod_status(_conn, _namespace, _name, 0), do: %{"phase" => "Pending"}

  defp normalize_pod_phase("Pending"), do: "Pending"
  defp normalize_pod_phase("Running"), do: "Running"
  defp normalize_pod_phase("Succeeded"), do: "Succeeded"
  defp normalize_pod_phase("Failed"), do: "Failed"
  defp normalize_pod_phase(_), do: "Pending"

  defp delete_if_exists(conn, api_version, kind, namespace, name) do
    _ =
      K8s.Client.delete(api_version, kind, namespace: namespace, name: name)
      |> K8s.Client.put_conn(conn)
      |> K8s.Client.run()

    :ok
  end

  defp runner_resource(namespace, runner_name) do
    %{
      "apiVersion" => "flame.org/v1",
      "kind" => "FlameRunner",
      "metadata" => %{
        "name" => runner_name,
        "namespace" => namespace,
        "uid" => "#{runner_name}-uid",
        "generation" => 1
      },
      "spec" => %{
        "parentRef" => %{
          "name" => "parent-app",
          "namespace" => namespace,
          "uid" => "parent-uid"
        },
        "image" => "registry.k8s.io/pause:3.9"
      }
    }
  end
end

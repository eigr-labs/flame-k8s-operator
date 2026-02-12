defmodule FlameK8sController.Handler.FlameRunnerHandler do
  @moduledoc """
  Handles FlameRunner resources by creating runner pods based on FlamePool templates.

  ## Workflow
  1. Receive FlameRunner resource
  2. Lookup referenced FlamePool (or use default-pool)
  3. Merge pool template with runner-specific overrides
  4. Create Pod resource as descendant
  5. Update FlameRunner status with pod details

  ## Example FlameRunner
  ```yaml
  apiVersion: flame.org/v1
  kind: FlameRunner
  metadata:
    name: runner-xyz123
    namespace: default
  spec:
    parentRef:
      name: my-app-pod
      namespace: default
      uid: "abc-123"
    image: docker.io/myapp/image:latest
    poolRef: custom-pool
    env:
      - name: CUSTOM_VAR
        value: "value"
  ```
  """

  alias FlameK8sController.K8s.Pod
  alias FlameK8sController.Operator

  require Logger

  @behaviour Pluggable

  @impl Pluggable
  def init(_opts), do: nil

  @impl Pluggable
  def call(%Bonny.Axn{action: action} = axn, nil) when action in [:add, :modify] do
    %Bonny.Axn{resource: resource, conn: conn} = axn

    with {:ok, args} <- parse_runner_args(resource),
         {:ok, pool_config} <- fetch_pool_config(conn, args),
         {:ok, pod_manifest} <- build_pod_manifest(args, pool_config) do
      axn
      |> Bonny.Axn.register_descendant(pod_manifest)
      |> update_runner_status(resource, :pending)
      |> Bonny.Axn.success_event()
    else
      {:error, reason} ->
        Logger.error("Failed to process FlameRunner: #{inspect(reason)}")

        axn
        |> update_runner_status(resource, :failed, reason)
        |> Bonny.Axn.failure_event(reason)
    end
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :delete} = axn, nil) do
    # Pod will be garbage collected by Kubernetes via owner references
    Bonny.Axn.success_event(axn)
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :reconcile} = axn, nil) do
    # Check if pod exists and update status accordingly
    %Bonny.Axn{resource: resource, conn: conn} = axn

    case get_runner_pod_status(conn, resource) do
      {:ok, pod_status} ->
        axn
        |> update_runner_status_from_pod(resource, pod_status)
        |> Bonny.Axn.success_event()

      {:error, _reason} ->
        # Pod might not exist yet or was deleted
        Bonny.Axn.success_event(axn)
    end
  end

  # Private functions

  defp parse_runner_args(resource) do
    args = Operator.get_args(resource)
    spec = args.params || %{}

    required_fields = [:parentRef, :image]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        is_nil(Map.get(spec, field)) and is_nil(Map.get(spec, to_string(field)))
      end)

    if missing_fields == [] do
      {:ok, Map.put(args, :spec, spec)}
    else
      {:error, "Missing required fields: #{inspect(missing_fields)}"}
    end
  end

  defp fetch_pool_config(conn, %{spec: spec, namespace: ns}) do
    pool_ref = Map.get(spec, "poolRef") || Map.get(spec, :poolRef) || "default-pool"

    # First try same namespace, then try flame namespace
    namespaces_to_try = [ns, "flame"]

    result =
      Enum.find_value(namespaces_to_try, fn namespace ->
        case K8s.Client.get("flame.org/v1", "FlamePool", namespace: namespace, name: pool_ref)
             |> K8s.Client.put_conn(conn)
             |> K8s.Client.run() do
          {:ok, pool} -> {:ok, pool}
          {:error, _} -> nil
        end
      end)

    case result do
      {:ok, pool} ->
        {:ok, pool}

      nil ->
        Logger.warning(
          "FlamePool '#{pool_ref}' not found in namespaces #{inspect(namespaces_to_try)}, using minimal defaults"
        )

        {:ok, minimal_pool_config()}
    end
  end

  defp minimal_pool_config do
    %{
      "spec" => %{
        "podTemplate" => %{
          "spec" => %{
            "containers" => [
              %{
                "env" => [],
                "resources" => %{
                  "requests" => %{"cpu" => "50m", "memory" => "128Mi"}
                }
              }
            ]
          }
        }
      }
    }
  end

  defp build_pod_manifest(args, pool_config) do
    try do
      pod_manifest = Pod.manifest(args, pool_config)
      {:ok, pod_manifest}
    rescue
      error ->
        {:error, "Failed to build pod manifest: #{Exception.message(error)}"}
    end
  end

  defp update_runner_status(axn, resource, phase, message \\ nil) do
    status = %{
      "observedGeneration" => Map.get(resource, "metadata", %{}) |> Map.get("generation", 1),
      "phase" => phase_to_string(phase),
      "conditions" => build_conditions(phase, message)
    }

    status =
      if message do
        Map.put(status, "message", message)
      else
        status
      end

    Bonny.Axn.update_status(axn, status)
  end

  defp update_runner_status_from_pod(axn, resource, pod_status) do
    status = %{
      "observedGeneration" => Map.get(resource, "metadata", %{}) |> Map.get("generation", 1),
      "phase" => pod_status["phase"] || "Unknown",
      "podName" => pod_status["name"],
      "podIP" => pod_status["podIP"],
      "conditions" => pod_status["conditions"] || []
    }

    status =
      if start_time = pod_status["startTime"] do
        Map.put(status, "startTime", start_time)
      else
        status
      end

    Bonny.Axn.update_status(axn, status)
  end

  defp get_runner_pod_status(conn, resource) do
    metadata = Map.get(resource, "metadata", %{})
    namespace = Map.get(metadata, "namespace", "default")
    name = Map.get(metadata, "name")

    # Pod name should match FlameRunner name
    case K8s.Client.get("v1", "Pod", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, pod} ->
        status = Map.get(pod, "status", %{})

        {:ok,
         %{
           "name" => name,
           "phase" => Map.get(status, "phase"),
           "podIP" => Map.get(status, "podIP"),
           "startTime" => Map.get(status, "startTime"),
           "conditions" => Map.get(status, "conditions", [])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp phase_to_string(phase) when is_atom(phase), do: phase |> to_string() |> String.capitalize()
  defp phase_to_string(phase) when is_binary(phase), do: phase

  defp build_conditions(phase, message) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base_condition = %{
      "lastTransitionTime" => now,
      "status" => "True"
    }

    case phase do
      :pending ->
        [
          Map.merge(base_condition, %{
            "type" => "Scheduled",
            "reason" => "PodCreated",
            "message" => "Runner pod is being scheduled"
          })
        ]

      :failed ->
        [
          Map.merge(base_condition, %{
            "type" => "Failed",
            "reason" => "CreationFailed",
            "message" => message || "Failed to create runner pod"
          })
        ]

      _ ->
        []
    end
  end
end

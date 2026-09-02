defmodule FlameK8sController.Handler.FlamePoolHandler do
  @moduledoc """
  Handles FlamePool resources.

  FlamePool resources define templates for runner pods.
  This handler validates the pool configuration and updates status.

  Example FlamePool:
  ```yaml
  apiVersion: flame.org/v1
  kind: FlamePool
  metadata:
    name: my-runner-pool
    namespace: default
  spec:
    podTemplate:
      spec:
        containers:
          - env:
              - name: PHX_SERVER
                value: "false"
              - name: MIX_ENV
                value: prod
            resources:
              limits:
                cpu: 200m
                memory: 200Mi
              requests:
                cpu: 200m
                memory: 200Mi
            volumeMounts:
              - mountPath: /app/.cache/bakeware/
                name: bakeware-cache
        volumes:
          - name: bakeware-cache
            emptyDir: {}
  ```
  """

  require Logger
  alias FlameK8sController.K8s.Pod

  @behaviour Pluggable
  @finalizer_id "flame.org/flamepool-protection"

  def finalizer_id, do: @finalizer_id

  @doc false
  def cleanup(%Bonny.Axn{} = axn) do
    resource = axn.resource
    metadata = Map.get(resource, "metadata", %{})
    namespace = Map.get(metadata, "namespace", "default")
    pool_name = Map.get(metadata, "name")

    case list_runners_in_namespace(axn.conn, namespace) do
      {:ok, runners} ->
        runners_using_pool =
          Enum.filter(runners, fn runner ->
            runner_pool_ref = get_in(runner, ["spec", "poolRef"]) || "default-pool"
            not deleting_resource?(runner) and runner_pool_ref == pool_name
          end)

        if runners_using_pool == [] do
          {:ok, Bonny.Axn.success_event(axn, message: "FlamePool cleanup completed")}
        else
          {:error,
           Bonny.Axn.failure_event(
             axn,
             message:
               "FlamePool is in use by #{length(runners_using_pool)} active FlameRunner resource(s)"
           )}
        end

      {:error, _reason} ->
        {:error, Bonny.Axn.failure_event(axn, message: "Unable to validate FlamePool cleanup")}
    end
  end

  @impl Pluggable
  def init(_opts), do: nil

  @impl Pluggable
  def call(%Bonny.Axn{action: action} = axn, nil) when action in [:add, :modify] do
    %Bonny.Axn{resource: resource} = axn

    case validate_pool_config(resource) do
      :ok ->
        conditions =
          sanitize_conditions([
            %{
              "type" => "Ready",
              "status" => "True",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "ConfigurationValid",
              "message" => "FlamePool configuration is valid"
            },
            %{
              "type" => "TemplateValid",
              "status" => "True",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "TemplateAccepted",
              "message" => "Pod template passed semantic validation"
            }
          ])

        axn
        |> Bonny.Axn.update_status(fn _current_status ->
          %{
            "observedGeneration" => get_in(resource, ["metadata", "generation"]) || 1,
            "phase" => "Ready",
            "reason" => "ConfigurationValid",
            "message" => "FlamePool configuration is valid",
            "lastUpdateTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "conditions" => conditions
          }
        end)
        |> Bonny.Axn.success_event()

      {:error, reason} ->
        Logger.warning("FlamePool validation failed: #{reason}")

        conditions =
          sanitize_conditions([
            %{
              "type" => "Ready",
              "status" => "False",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "ConfigurationInvalid",
              "message" => reason
            },
            %{
              "type" => "TemplateValid",
              "status" => "False",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "TemplateRejected",
              "message" => reason
            }
          ])

        axn
        |> Bonny.Axn.update_status(fn _current_status ->
          %{
            "observedGeneration" => get_in(resource, ["metadata", "generation"]) || 1,
            "phase" => "Invalid",
            "reason" => "ConfigurationInvalid",
            "message" => reason,
            "lastUpdateTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "conditions" => conditions
          }
        end)
        |> Bonny.Axn.failure_event(message: reason)
    end
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :delete} = axn, nil) do
    # Pool deletion is allowed - runners can continue using cached config
    # or fall back to default-pool
    Logger.info("FlamePool deleted")
    Bonny.Axn.success_event(axn)
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :reconcile} = axn, nil) do
    # Re-validate on reconciliation
    call(Map.put(axn, :action, :modify), nil)
  end

  # Validate pool configuration
  defp validate_pool_config(resource) do
    spec = Map.get(resource, "spec", %{})
    pod_template = Map.get(spec, "podTemplate", %{})
    pod_spec = Map.get(pod_template, "spec", %{})
    containers = Map.get(pod_spec, "containers", [])

    cond do
      is_nil(pod_template) or pod_template == %{} ->
        {:error, "podTemplate is required"}

      is_nil(pod_spec) or pod_spec == %{} ->
        {:error, "podTemplate.spec is required"}

      not is_list(containers) ->
        {:error, "podTemplate.spec.containers must be a list"}

      is_nil(containers) or containers == [] ->
        {:error, "At least one container must be defined in podTemplate.spec"}

      Enum.any?(containers, &(not is_map(&1))) ->
        {:error, "Each entry in podTemplate.spec.containers must be an object"}

      Enum.any?(containers, &invalid_env_entries?/1) ->
        {:error, "Each container env entry must include a non-empty name"}

      true ->
        validate_container_resources(containers)
    end
  end

  defp validate_container_resources(containers) do
    containers
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {container, index} ->
      case Pod.validate_resources(container) do
        :ok ->
          nil

        {:error, reason} ->
          {:error, "Invalid resources in podTemplate.spec.containers[#{index}]: #{reason}"}
      end
    end)
  end

  @doc false
  def sanitize_conditions(conditions) when is_list(conditions) do
    conditions
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn condition ->
      %{}
      |> put_if_present("type", Map.get(condition, "type"))
      |> put_if_present("status", Map.get(condition, "status"))
      |> put_if_present("lastTransitionTime", Map.get(condition, "lastTransitionTime"))
      |> put_if_present("reason", Map.get(condition, "reason"))
      |> put_if_present("message", Map.get(condition, "message"))
    end)
    |> Enum.filter(fn condition ->
      Map.get(condition, "type") not in [nil, ""] and
        Map.get(condition, "status") not in [nil, ""]
    end)
  end

  def sanitize_conditions(_), do: []

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp invalid_env_entries?(container) do
    env = Map.get(container, "env", [])

    if is_list(env) do
      Enum.any?(env, fn env_entry ->
        not is_map(env_entry) or
          is_nil(Map.get(env_entry, "name")) or
          Map.get(env_entry, "name") == ""
      end)
    else
      true
    end
  end

  defp list_runners_in_namespace(conn, namespace) do
    case K8s.Client.list("flame.org/v1", "FlameRunner", namespace: namespace)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, response} -> {:ok, Map.get(response, "items", [])}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp deleting_resource?(resource) do
    resource
    |> Map.get("metadata", %{})
    |> Map.has_key?("deletionTimestamp")
  end
end

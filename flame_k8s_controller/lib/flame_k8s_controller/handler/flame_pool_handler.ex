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

  @behaviour Pluggable

  @impl Pluggable
  def init(_opts), do: nil

  @impl Pluggable
  def call(%Bonny.Axn{action: action} = axn, nil) when action in [:add, :modify] do
    %Bonny.Axn{resource: resource} = axn

    case validate_pool_config(resource) do
      :ok ->
        axn
        |> Bonny.Axn.update_status(%{
          "observedGeneration" => get_in(resource, ["metadata", "generation"]) || 1,
          "conditions" => [
            %{
              "type" => "Ready",
              "status" => "True",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "ConfigurationValid",
              "message" => "FlamePool configuration is valid"
            }
          ]
        })
        |> Bonny.Axn.success_event()

      {:error, reason} ->
        Logger.warning("FlamePool validation failed: #{reason}")

        axn
        |> Bonny.Axn.update_status(%{
          "observedGeneration" => get_in(resource, ["metadata", "generation"]) || 1,
          "conditions" => [
            %{
              "type" => "Ready",
              "status" => "False",
              "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "reason" => "ConfigurationInvalid",
              "message" => reason
            }
          ]
        })
        |> Bonny.Axn.failure_event(reason)
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

      is_nil(containers) or containers == [] ->
        {:error, "At least one container must be defined in podTemplate.spec"}

      true ->
        :ok
    end
  end
end

defmodule FlameK8sController.Handler.FlameRunnerHandler do
  @moduledoc """
  Handles FlameRunner resources by creating and tracking runner pods
  based on FlamePool templates.

  This module is the core reconciliation logic for the `FlameRunner` CRD.

  ## Workflow

  1. Parse and validate required `spec` fields from `FlameRunner`
  2. Resolve `FlamePool` (`spec.poolRef`, default `default-pool`)
  3. Fallback to minimal pool configuration when pool cannot be resolved
  4. Build Pod manifest by merging pool template and runner overrides
  5. Register Pod as descendant and update `FlameRunner.status`
  6. On reconcile, mirror Pod status back into `FlameRunner.status`
  7. On deletion, run finalizer cleanup and mark runner as `Terminating`

  ## Input CRD Example

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
    image: ghcr.io/example/runner:latest
    poolRef: custom-pool
    terminationGracePeriodSeconds: 60
    env:
      - name: CUSTOM_ENV
        value: "1"
  ```

  ## Status Example

  ```yaml
  status:
    observedGeneration: 3
    phase: Running
    reason: PodRunning
    message: Runner pod is running
    podName: runner-xyz123
    podIP: 10.42.0.15
    retryCount: 0
    poolRef: custom-pool
    poolNamespace: default
    fallbackPoolUsed: false
    startTime: "2026-09-01T10:00:00Z"
    completionTime: null
    lastUpdateTime: "2026-09-01T10:00:15Z"
    conditions:
      - type: Ready
        status: "True"
        reason: PodRunning
        message: Runner pod is running
        lastTransitionTime: "2026-09-01T10:00:15Z"
  ```

  ## Retry and Fallback Behavior

  - If referenced pool does not exist, the handler uses a minimal fallback pool.
  - `status.fallbackPoolUsed` is set to `true` for traceability.
  - During reconcile, missing pod lookups keep the runner in `NotProvisioned`.
  - Only terminal reconcile errors transition the runner to `Failed`.

  ## Finalizer Behavior

  Finalizer id: `flame.org/flamerunner-cleanup`

  During deletion, this module:

  - sets `status.phase` to `Terminating`
  - attempts pod cleanup (`v1/Pod` with same name/namespace)
  - removes the finalizer only after cleanup step succeeds
  """

  alias FlameK8sController.K8s.CookieSecret
  alias FlameK8sController.K8s.Pod
  alias FlameK8sController.Operator

  require Logger

  @behaviour Pluggable
  @finalizer_id "flame.org/flamerunner-cleanup"
  @default_retention_limit 5

  @doc false
  def runner_retention_limit do
    case System.get_env("FLAME_RUNNER_RETENTION_LIMIT") do
      nil -> @default_retention_limit
      "" -> @default_retention_limit
      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> @default_retention_limit
        end
    end
  end

  @doc false
  def garbage_collect_completed_runners(conn, namespace, current_resource) do
    limit = runner_retention_limit()

    if limit <= 0 do
      Logger.info("FlameRunner retention GC skipped: limit is #{limit}")
      :ok
    else
      current_name = get_in(current_resource, ["metadata", "name"])
      current_parent = get_in(current_resource, ["spec", "parentRef", "name"]) || get_in(current_resource, ["spec", :parentRef, :name])

      case K8s.Client.list("flame.org/v1", "FlameRunner", namespace: namespace)
           |> K8s.Client.put_conn(conn)
           |> K8s.Client.run() do
        {:ok, %{"items" => items}} ->
          candidates =
            items
            |> Enum.filter(fn runner ->
              runner_parent = get_in(runner, ["spec", "parentRef", "name"]) || get_in(runner, ["spec", :parentRef, :name])
              phase = get_in(runner, ["status", "phase"])
              runner_name = get_in(runner, ["metadata", "name"])
              runner_parent == current_parent and phase in ["Succeeded", "Failed"] and runner_name != current_name and not deleting_resource?(runner)
            end)
            |> Enum.sort_by(fn runner ->
              get_in(runner, ["metadata", "creationTimestamp"]) || "0000-01-01T00:00:00Z"
            end, :desc)
            |> Enum.drop(limit)

          Logger.info(
            "FlameRunner retention GC in #{namespace}: parent=#{current_parent || "unknown"} limit=#{limit} candidates=#{length(candidates)}"
          )

          Enum.each(candidates, fn runner ->
            runner_name = get_in(runner, ["metadata", "name"])

            case K8s.Client.delete("flame.org/v1", "FlameRunner", namespace: namespace, name: runner_name)
                 |> K8s.Client.put_conn(conn)
                 |> K8s.Client.run() do
              {:ok, _} ->
                Logger.info("Deleted stale completed FlameRunner #{namespace}/#{runner_name} due to retention policy")

              {:error, reason} ->
                Logger.warning("Failed to delete stale completed FlameRunner #{namespace}/#{runner_name}: #{inspect(reason)}")
            end
          end)

          :ok

        {:error, reason} ->
          Logger.warning("Unable to garbage collect completed runners in #{namespace}: #{inspect(reason)}")
          :ok
      end
    end
  end

  @doc false
  def maybe_gc_completed_runners(conn, resource) do
    phase = get_in(resource, ["status", "phase"])

    if phase in ["Succeeded", "Failed"] do
      namespace = get_in(resource, ["metadata", "namespace"]) || "default"
      Logger.info("Checking retention GC for completed FlameRunner #{namespace}/#{get_in(resource, ["metadata", "name"])} (phase=#{phase})")
      garbage_collect_completed_runners(conn, namespace, resource)
    else
      :ok
    end
  end

  defp parse_runner_args(resource) do
    args = Operator.get_args(resource)
    spec = args.params || %{}
    parent_ref = Map.get(spec, "parentRef") || Map.get(spec, :parentRef) || %{}
    image = Map.get(spec, "image") || Map.get(spec, :image)

    cond do
      is_nil(image) or image == "" ->
        {:error, "Missing required field: image"}

      not is_map(parent_ref) ->
        {:error, "parentRef must be a map"}

      missing_parent_ref_fields(parent_ref) != [] ->
        {:error,
         "Missing required parentRef fields: #{inspect(missing_parent_ref_fields(parent_ref))}"}

      true ->
        {:ok, Map.put(args, :spec, spec)}
    end
  end

  defp missing_parent_ref_fields(parent_ref) do
    [:name, :namespace]
    |> Enum.filter(fn field ->
      value = Map.get(parent_ref, field) || Map.get(parent_ref, to_string(field))
      is_nil(value) or value == ""
    end)
  end

  defp fetch_pool_config(conn, %{spec: spec, namespace: ns}) do
    pool_ref = Map.get(spec, "poolRef") || Map.get(spec, :poolRef) || "default-pool"
    namespaces_to_try = [ns, "flame"]

    result =
      Enum.find_value(namespaces_to_try, fn namespace ->
        try do
          case K8s.Client.get("flame.org/v1", "FlamePool", namespace: namespace, name: pool_ref)
               |> K8s.Client.put_conn(conn)
               |> K8s.Client.run() do
            {:ok, pool} -> {:ok, pool, namespace}
            {:error, _} -> nil
          end
        rescue
          _ -> nil
        end
      end)

    case result do
      {:ok, pool, namespace} ->
        {:ok, pool, pool_resolution(pool_ref, namespace, false)}

      nil ->
        Logger.warning(
          "FlamePool '#{pool_ref}' not found in namespaces #{inspect(namespaces_to_try)}, using minimal defaults"
        )

        {:ok, minimal_pool_config(), pool_resolution(pool_ref, ns, true)}
    end
  end

  defp pool_resolution(pool_ref, pool_namespace, fallback_pool_used) do
    %{
      "poolRef" => pool_ref,
      "poolNamespace" => pool_namespace,
      "fallbackPoolUsed" => fallback_pool_used
    }
  end

  defp minimal_pool_config do
    %{
      "spec" => %{
        "podTemplate" => %{
          "spec" => %{
            "containers" => [
              %{
                "env" => [],
                "resources" => %{"requests" => %{"cpu" => "50m", "memory" => "128Mi"}}
              }
            ]
          }
        }
      }
    }
  end

  defp build_pod_manifest(args, pool_config) do
    try do
      {:ok, Pod.manifest(args, pool_config)}
    rescue
      error -> {:error, "Failed to build pod manifest: #{Exception.message(error)}"}
    end
  end

  defp ensure_runner_cookie_secret(conn, %{namespace: namespace, spec: spec}) do
    cookie_secret_ref = Map.get(spec, "cookieSecretRef") || Map.get(spec, :cookieSecretRef) || "flame-erlang-cookie"

    CookieSecret.ensure_namespace_secret(namespace, cookie_secret_ref, conn: conn)
  end

  defp update_runner_status(axn, resource, phase, message),
    do: update_runner_status(axn, resource, phase, message, %{})

  defp update_runner_status(axn, resource, phase, message, extra_status) do
    status = build_phase_status(resource, phase, message, extra_status)

    Bonny.Axn.update_status(axn, fn current_status ->
      current_status
      |> Map.new()
      |> Map.merge(status)
    end)
  end

  defp update_runner_status_from_pod(axn, resource, pod_status) do
    status = build_status_from_pod(resource, pod_status)

    Bonny.Axn.update_status(axn, fn current_status ->
      current_status
      |> Map.new()
      |> Map.merge(status)
      |> Map.put("retryCount", 0)
    end)
  end

  defp build_phase_status(resource, phase, message, extra_status) do
    metadata = Map.get(resource, "metadata", %{})

    status = %{
      "observedGeneration" => Map.get(metadata, "generation", 1),
      "phase" => phase_to_string(phase),
      "reason" => phase_reason(phase),
      "conditions" => build_conditions(phase, message),
      "lastUpdateTime" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    status =
      if phase in [:not_provisioned, :pending, :terminating] do
        Map.put(status, "podName", Map.get(metadata, "name"))
      else
        status
      end

    status = if message, do: Map.put(status, "message", message), else: status

    Map.merge(status, extra_status)
  end

  @doc false
  def build_status_from_pod(resource, pod_status) do
    phase = normalize_runner_phase(pod_status["phase"])
    phase_atom = String.downcase(phase) |> String.to_atom()
    message = pod_status["message"] || phase_message(phase_atom)
    reason = pod_status["reason"] || phase_reason(phase_atom)
    conditions =
      pod_status["conditions"]
      |> sanitize_pod_conditions()
      |> case do
        [] -> build_conditions(phase_atom, message)
        sanitized -> sanitized
      end

    status = %{
      "observedGeneration" => Map.get(resource, "metadata", %{}) |> Map.get("generation", 1),
      "phase" => phase,
      "reason" => reason,
      "podName" => pod_status["name"],
      "conditions" => conditions,
      "message" => message,
      "lastUpdateTime" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    status = put_if_present(status, "podIP", pod_status["podIP"])

    status =
      if start_time = pod_status["startTime"] do
        Map.put(status, "startTime", start_time)
      else
        status
      end

    if completion_time = pod_status["completionTime"] do
      Map.put(status, "completionTime", completion_time)
    else
      status
    end
  end

  defp get_runner_pod_status(conn, resource) do
    metadata = Map.get(resource, "metadata", %{})
    namespace = Map.get(metadata, "namespace", "default")
    name = Map.get(metadata, "name")

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
           "completionTime" => extract_completion_time(status),
           "conditions" => Map.get(status, "conditions", []),
           "reason" => extract_pod_reason(status),
           "message" => extract_pod_message(status)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_missing_runner_pod(axn, resource, reason) do
    retry_count = current_retry_count(resource) + 1

    if pod_not_found_error?(reason) do
      case ensure_runner_descendant(axn, resource) do
        {:ok, axn_with_descendant} ->
          axn_with_descendant
          |> update_runner_status(
            resource,
            :not_provisioned,
            "Runner pod is being provisioned",
            %{"retryCount" => retry_count, "reason" => "PodNotProvisioned"}
          )
          |> Bonny.Axn.success_event(
            message: "Runner pod is being provisioned, retry #{retry_count}"
          )

        {:error, ensure_error} ->
          axn
          |> update_runner_status(
            resource,
            :failed,
            "Failed to ensure runner pod descendant",
            %{"retryCount" => retry_count, "reason" => "PodEnsureFailed"}
          )
          |> Bonny.Axn.failure_event(message: "Failed to ensure runner pod descendant: #{ensure_error}")
      end
    else
      axn
      |> update_runner_status(
        resource,
        :failed,
        "Runner pod lookup failed",
        %{"retryCount" => retry_count, "reason" => "PodLookupFailed"}
      )
      |> Bonny.Axn.failure_event(message: "Runner pod lookup failed: #{inspect(reason)}")
    end
  end

  defp deleting_resource?(resource) do
    resource
    |> Map.get("metadata", %{})
    |> Map.has_key?("deletionTimestamp")
  end

  defp current_retry_count(resource) do
    case get_in(resource, ["status", "retryCount"]) do
      retry_count when is_integer(retry_count) and retry_count >= 0 -> retry_count
      _ -> 0
    end
  end

  defp delete_runner_pod(conn, namespace, name) do
    case K8s.Client.delete("v1", "Pod", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _} -> :ok
      {:error, reason} -> if pod_not_found_error?(reason), do: :ok, else: {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp pod_not_found_error?(%K8s.Client.APIError{reason: "NotFound"}), do: true
  defp pod_not_found_error?(%{reason: "NotFound"}), do: true
  defp pod_not_found_error?(%{status: 404}), do: true
  defp pod_not_found_error?(_), do: false

  defp ensure_runner_descendant(%Bonny.Axn{conn: conn} = axn, resource) do
    with {:ok, args} <- parse_runner_args(resource),
         :ok <- ensure_runner_cookie_secret(conn, args),
         {:ok, pool_config, _pool_resolution} <- fetch_pool_config(conn, args),
         {:ok, pod_manifest} <- build_pod_manifest(args, pool_config),
         :ok <- validate_runner_pod_manifest(pod_manifest) do
      {:ok, Bonny.Axn.register_descendant(axn, pod_manifest)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_runner_pod_manifest(pod_manifest) do
    case get_in(pod_manifest, ["spec", "containers"]) do
      [container | _] ->
        Pod.validate_resources(container)

      _ ->
        {:error, "Runner pod manifest must contain at least one container"}
    end
  end

  defp apply_status_patch(conn, resource, status) do
    resource
    |> Map.put("status", status)
    |> Bonny.Resource.apply_status(conn)
  rescue
    _ -> :noop
  end

  defp phase_to_string(:not_provisioned), do: "NotProvisioned"
  defp phase_to_string(phase) when is_atom(phase), do: phase |> to_string() |> String.capitalize()
  defp phase_to_string(phase) when is_binary(phase), do: phase

  defp normalize_runner_phase("Pending"), do: "Pending"
  defp normalize_runner_phase("Running"), do: "Running"
  defp normalize_runner_phase("Succeeded"), do: "Succeeded"
  defp normalize_runner_phase("Failed"), do: "Failed"
  defp normalize_runner_phase("Terminating"), do: "Terminating"
  defp normalize_runner_phase(_), do: "Pending"

  defp phase_reason(:not_provisioned), do: "PodNotProvisioned"
  defp phase_reason(:pending), do: "PodPending"
  defp phase_reason(:running), do: "PodRunning"
  defp phase_reason(:succeeded), do: "PodSucceeded"
  defp phase_reason(:failed), do: "PodFailed"
  defp phase_reason(:terminating), do: "PodTerminating"
  defp phase_reason(_), do: "RunnerUpdated"

  defp phase_message(:not_provisioned), do: "Runner pod has not been created yet"
  defp phase_message(:pending), do: "Runner pod is pending"
  defp phase_message(:running), do: "Runner pod is running"
  defp phase_message(:succeeded), do: "Runner pod completed successfully"
  defp phase_message(:failed), do: "Runner pod failed"
  defp phase_message(:terminating), do: "Runner pod is terminating"
  defp phase_message(_), do: "Runner status updated"

  defp extract_completion_time(status) do
    statuses = Map.get(status, "containerStatuses", [])

    statuses
    |> Enum.find_value(fn container_status ->
      container_status
      |> Map.get("state", %{})
      |> Map.get("terminated", %{})
      |> Map.get("finishedAt")
    end)
  end

  defp extract_pod_reason(status) do
    statuses = Map.get(status, "containerStatuses", [])

    Enum.find_value(statuses, fn container_status ->
      container_status
      |> Map.get("state", %{})
      |> Map.get("terminated", %{})
      |> Map.get("reason")
    end)
  end

  defp extract_pod_message(status) do
    statuses = Map.get(status, "containerStatuses", [])

    Enum.find_value(statuses, fn container_status ->
      container_status
      |> Map.get("state", %{})
      |> Map.get("terminated", %{})
      |> Map.get("message")
    end)
  end

  defp sanitize_pod_conditions(conditions) when is_list(conditions) do
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

  defp sanitize_pod_conditions(_), do: []

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp build_conditions(phase, message) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base_condition = %{"lastTransitionTime" => now, "status" => "True"}

    case phase do
      :not_provisioned ->
        [
          Map.merge(base_condition, %{
            "type" => "Ready",
            "status" => "Unknown",
            "reason" => "PodNotProvisioned",
            "message" => message || "Runner pod has not been created yet"
          })
        ]

      :pending ->
        [
          Map.merge(base_condition, %{
            "type" => "Ready",
            "status" => "Unknown",
            "reason" => "PodCreated",
            "message" => "Runner pod is being scheduled"
          })
        ]

      :running ->
        [
          Map.merge(base_condition, %{
            "type" => "Ready",
            "reason" => "PodRunning",
            "message" => "Runner pod is running"
          })
        ]

      :succeeded ->
        [
          Map.merge(base_condition, %{
            "type" => "Completed",
            "reason" => "PodSucceeded",
            "message" => "Runner pod completed successfully"
          })
        ]

      :failed ->
        [
          Map.merge(base_condition, %{
            "type" => "Failed",
            "status" => "False",
            "reason" => "CreationFailed",
            "message" => message || "Failed to create runner pod"
          })
        ]

      :terminating ->
        [
          Map.merge(base_condition, %{
            "type" => "Terminating",
            "status" => "Unknown",
            "reason" => "ResourceDeleting",
            "message" => message || "Runner resource is terminating"
          })
        ]

      _ ->
        []
    end
  end

  @doc false
  def finalizer_id, do: @finalizer_id

  @doc false
  def cleanup(%Bonny.Axn{} = axn) do
    resource = axn.resource
    metadata = Map.get(resource, "metadata", %{})
    namespace = Map.get(metadata, "namespace", "default")
    name = Map.get(metadata, "name")

    Logger.info("Finalizer cleanup triggered for FlameRunner #{namespace}/#{name}")

    terminating_status =
      build_phase_status(resource, :terminating, "Runner resource is terminating", %{
        "podName" => name,
        "retryCount" => current_retry_count(resource)
      })

    _ = apply_status_patch(axn.conn, resource, terminating_status)

    case delete_runner_pod(axn.conn, namespace, name) do
      :ok -> {:ok, Bonny.Axn.success_event(axn, message: "Runner pod cleanup completed")}
      {:error, _reason} -> {:error, Bonny.Axn.failure_event(axn, message: "Failed to cleanup runner pod")}
    end
  end

  @impl Pluggable
  def init(_opts), do: nil

  @impl Pluggable
  def call(
        %Bonny.Axn{action: action, resource: %{"metadata" => %{"deletionTimestamp" => _}}} = axn,
        nil
      )
      when action in [:add, :modify] do
    %Bonny.Axn{resource: resource} = axn

    axn
    |> update_runner_status(resource, :terminating, "Runner resource is terminating")
    |> Bonny.Axn.success_event(message: "Runner resource is terminating")
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: action} = axn, nil) when action in [:add, :modify] do
    %Bonny.Axn{resource: resource, conn: conn} = axn

    with {:ok, args} <- parse_runner_args(resource),
         :ok <- ensure_runner_cookie_secret(conn, args),
         {:ok, pool_config, pool_resolution} <- fetch_pool_config(conn, args),
         {:ok, pod_manifest} <- build_pod_manifest(args, pool_config),
         :ok <- validate_runner_pod_manifest(pod_manifest) do
      axn
      |> Bonny.Axn.register_descendant(pod_manifest)
      |> update_runner_status(resource, :not_provisioned, nil, Map.put(pool_resolution, "retryCount", 0))
      |> Bonny.Axn.success_event()
    else
      {:error, reason} ->
        Logger.error("Failed to process FlameRunner: #{inspect(reason)}")

        axn
        |> update_runner_status(resource, :failed, reason)
        |> Bonny.Axn.failure_event(message: reason)
    end
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :delete} = axn, nil) do
    Bonny.Axn.success_event(axn)
  end

  @impl Pluggable
  def call(%Bonny.Axn{action: :reconcile} = axn, nil) do
    %Bonny.Axn{resource: resource, conn: conn} = axn

    if deleting_resource?(resource) do
      Logger.info("FlameRunner is marked for deletion: #{get_in(resource, ["metadata", "namespace"])}/#{get_in(resource, ["metadata", "name"])}")

      axn
      |> update_runner_status(resource, :terminating, "Runner resource is terminating")
      |> Bonny.Axn.success_event(message: "Runner resource is terminating")
    else
      case get_runner_pod_status(conn, resource) do
        {:ok, pod_status} ->
          updated_axn =
            axn
            |> update_runner_status_from_pod(resource, pod_status)

          Bonny.Axn.success_event(updated_axn)

        {:error, reason} ->
          handle_missing_runner_pod(axn, resource, reason)
      end
    end
  end
end

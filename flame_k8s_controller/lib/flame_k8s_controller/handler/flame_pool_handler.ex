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
  @max_matching_node_names 3

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
    %Bonny.Axn{resource: resource, conn: conn} = axn

    case validate_pool_config(resource) do
      :ok ->
        resolved_scheduling = Pod.resolved_scheduling(resource)

        with :ok <- ensure_priority_class_for_pool(conn, resolved_scheduling) do
          scheduling_feedback = evaluate_scheduling_feedback(conn, resolved_scheduling)

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
              },
              %{
                "type" => "SchedulingResolved",
                "status" => "True",
                "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "reason" => "SchedulingTranslated",
                "message" => "High-level scheduling was translated into PodSpec defaults"
              },
              %{
                "type" => "SchedulingInfrastructure",
                "status" => infra_ready_condition_status(scheduling_feedback),
                "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "reason" => infra_ready_condition_reason(scheduling_feedback),
                "message" => infra_ready_condition_message(scheduling_feedback)
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
              "conditions" => conditions,
              "resolvedScheduling" => resolved_scheduling,
              "schedulingFeedback" => scheduling_feedback
            }
          end)
          |> Bonny.Axn.success_event(
            message:
              "FlamePool configuration is valid (scheduling infra ready: #{scheduling_feedback["infraReady"]})"
          )
        else
          {:error, reason} ->
            Logger.warning("FlamePool priority class reconciliation failed: #{reason}")

            conditions =
              sanitize_conditions([
                %{
                  "type" => "Ready",
                  "status" => "False",
                  "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "reason" => "PriorityClassEnsureFailed",
                  "message" => reason
                },
                %{
                  "type" => "SchedulingResolved",
                  "status" => "True",
                  "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "reason" => "SchedulingTranslated",
                  "message" => "High-level scheduling was translated into PodSpec defaults"
                },
                %{
                  "type" => "SchedulingInfrastructure",
                  "status" => "Unknown",
                  "lastTransitionTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                  "reason" => "InfrastructureCheckSkipped",
                  "message" => "Infrastructure check skipped because priority class ensure failed"
                }
              ])

            axn
            |> Bonny.Axn.update_status(fn _current_status ->
              %{
                "observedGeneration" => get_in(resource, ["metadata", "generation"]) || 1,
                "phase" => "Invalid",
                "reason" => "PriorityClassEnsureFailed",
                "message" => reason,
                "lastUpdateTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "conditions" => conditions,
                "resolvedScheduling" => resolved_scheduling,
                "schedulingFeedback" => %{
                  "infraReady" => "Unknown",
                  "matchingNodes" => 0,
                  "matchingNodesNames" => "[]",
                  "message" => "Priority class reconcile failed: #{reason}"
                }
              }
            end)
            |> Bonny.Axn.failure_event(message: reason)
        end

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
    scheduling = Map.get(spec, "scheduling") || %{}
    pod_template = Map.get(spec, "podTemplate", %{})
    pod_spec = Map.get(pod_template, "spec", %{})
    containers = Map.get(pod_spec, "containers", [])

    with :ok <- validate_scheduling_config(scheduling) do
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
  end

  defp validate_scheduling_config(nil), do: :ok

  defp validate_scheduling_config(scheduling) when is_map(scheduling) do
    with :ok <- validate_enum_field(scheduling, "provider", ["generic", "karpenter"]),
         :ok <- validate_enum_field(scheduling, "class", ["general", "cpu", "memory", "gpu"]),
         :ok <- validate_enum_field(scheduling, "lifecycle", ["any", "on-demand", "spot"]),
         :ok <- validate_enum_field(scheduling, "architecture", ["any", "amd64", "arm64"]),
         :ok <- validate_enum_field(scheduling, "priority", ["low", "normal", "high", "critical"]) do
      :ok
    end
  end

  defp validate_scheduling_config(_), do: {:error, "spec.scheduling must be an object"}

  defp validate_enum_field(map, field, allowed_values) do
    case Map.get(map, field) do
      nil ->
        :ok

      "" ->
        :ok

      value ->
        if Enum.member?(allowed_values, value) do
          :ok
        else
          {:error,
           "spec.scheduling.#{field} has invalid value #{inspect(value)}. Allowed values: #{Enum.join(allowed_values, ", ")}"}
        end
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

  defp ensure_priority_class_for_pool(nil, _resolved_scheduling), do: :ok

  defp ensure_priority_class_for_pool(conn, resolved_scheduling) do
    priority_class_name = get_in(resolved_scheduling, ["effective", "priorityClassName"])

    case priority_class_name do
      name when is_binary(name) and name in ["flame-low", "flame-normal", "flame-high", "flame-critical"] ->
        ensure_priority_class(conn, name)

      _ ->
        :ok
    end
  end

  defp ensure_priority_class(conn, name) do
    case K8s.Client.get("scheduling.k8s.io/v1", "PriorityClass", name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _} ->
        :ok

      {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
        create_priority_class(conn, name)

      {:error, reason} ->
        {:error, "Unable to fetch PriorityClass #{name}: #{inspect(reason)}"}
    end
  end

  defp create_priority_class(conn, name) do
    manifest = priority_class_manifest(name)

    case K8s.Client.create(manifest)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _} ->
        :ok

      {:error, %K8s.Client.APIError{reason: "AlreadyExists"}} ->
        :ok

      {:error, reason} ->
        {:error, "Unable to create PriorityClass #{name}: #{inspect(reason)}"}
    end
  end

  defp priority_class_manifest("flame-low") do
    %{
      "apiVersion" => "scheduling.k8s.io/v1",
      "kind" => "PriorityClass",
      "metadata" => %{"name" => "flame-low"},
      "value" => 10_000,
      "globalDefault" => false,
      "description" => "FLAME low priority class"
    }
  end

  defp priority_class_manifest("flame-normal") do
    %{
      "apiVersion" => "scheduling.k8s.io/v1",
      "kind" => "PriorityClass",
      "metadata" => %{"name" => "flame-normal"},
      "value" => 100_000,
      "globalDefault" => false,
      "description" => "FLAME normal priority class"
    }
  end

  defp priority_class_manifest("flame-high") do
    %{
      "apiVersion" => "scheduling.k8s.io/v1",
      "kind" => "PriorityClass",
      "metadata" => %{"name" => "flame-high"},
      "value" => 900_000,
      "globalDefault" => false,
      "description" => "FLAME high priority class"
    }
  end

  defp priority_class_manifest("flame-critical") do
    %{
      "apiVersion" => "scheduling.k8s.io/v1",
      "kind" => "PriorityClass",
      "metadata" => %{"name" => "flame-critical"},
      "value" => 1_000_000,
      "globalDefault" => false,
      "description" => "FLAME critical priority class"
    }
  end

  defp evaluate_scheduling_feedback(nil, _resolved_scheduling) do
    %{
      "infraReady" => "Unknown",
      "matchingNodes" => 0,
      "matchingNodesNames" => "[]",
      "message" => "Node matching was skipped because no Kubernetes connection was available"
    }
  end

  defp evaluate_scheduling_feedback(conn, resolved_scheduling) do
    effective_selector = get_in(resolved_scheduling, ["effective", "nodeSelector"]) || %{}

    if map_size(effective_selector) == 0 do
      %{
        "infraReady" => "Unknown",
        "matchingNodes" => 0,
        "matchingNodesNames" => "[]",
        "message" => "No scheduling selector was generated. Pod scheduling depends on default scheduler behavior or explicit podTemplate settings"
      }
    else
      case K8s.Client.list("v1", "Node")
           |> K8s.Client.put_conn(conn)
           |> K8s.Client.run() do
        {:ok, %{"items" => nodes}} ->
          matching_node_names =
            nodes
            |> Enum.filter(fn node ->
              labels = get_in(node, ["metadata", "labels"]) || %{}
              Enum.all?(effective_selector, fn {key, value} -> Map.get(labels, key) == value end)
            end)
            |> Enum.map(fn node -> get_in(node, ["metadata", "name"]) end)
            |> Enum.reject(&is_nil/1)

          formatted_names = format_matching_nodes_names_for_status(matching_node_names)

          %{
            "infraReady" => if(formatted_names.matching_nodes > 0, do: "True", else: "False"),
            "matchingNodes" => formatted_names.matching_nodes,
            "matchingNodesNames" => formatted_names.matching_nodes_names,
            "message" =>
              if(formatted_names.matching_nodes > 0,
                do: "Found #{formatted_names.matching_nodes} node(s) matching resolved scheduling selectors",
                else: "No nodes matched resolved scheduling selectors. Ensure infrastructure labels/taints are configured"
              )
          }

        {:error, reason} ->
          %{
            "infraReady" => "Unknown",
            "matchingNodes" => 0,
            "matchingNodesNames" => "[]",
            "message" => "Unable to evaluate scheduling selectors against cluster nodes: #{inspect(reason)}"
          }
      end
    end
  rescue
    error ->
      %{
        "infraReady" => "Unknown",
        "matchingNodes" => 0,
        "matchingNodesNames" => "[]",
        "message" => "Unexpected error while evaluating scheduling selectors: #{inspect(error)}"
      }
  end

  @doc false
  def format_matching_nodes_names_for_status(node_names, max_names \\ @max_matching_node_names)

  def format_matching_nodes_names_for_status(node_names, max_names)
      when is_list(node_names) and is_integer(max_names) and max_names > 0 do
    matching_nodes = length(node_names)
    displayed_node_names = Enum.take(node_names, max_names)
    matching_nodes_omitted = max(matching_nodes - length(displayed_node_names), 0)

    %{
      matching_nodes: matching_nodes,
      matching_nodes_names: format_matching_nodes_names(displayed_node_names, matching_nodes_omitted)
    }
  end

  def format_matching_nodes_names_for_status(node_names, _max_names) when is_list(node_names) do
    format_matching_nodes_names_for_status(node_names, @max_matching_node_names)
  end

  defp format_matching_nodes_names(displayed_node_names, omitted_nodes) do
    suffix = if omitted_nodes > 0, do: ",...", else: ""

    "[" <> Enum.join(displayed_node_names, ",") <> suffix <> "]"
  end

  defp infra_ready_condition_status(%{"infraReady" => "True"}), do: "True"
  defp infra_ready_condition_status(%{"infraReady" => "False"}), do: "False"
  defp infra_ready_condition_status(_), do: "Unknown"

  defp infra_ready_condition_reason(%{"infraReady" => "True"}), do: "MatchingNodesFound"
  defp infra_ready_condition_reason(%{"infraReady" => "False"}), do: "NoMatchingNodes"
  defp infra_ready_condition_reason(_), do: "InfrastructureCheckSkipped"

  defp infra_ready_condition_message(%{"message" => message}), do: message
  defp infra_ready_condition_message(_), do: "Scheduling infrastructure feedback not available"

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

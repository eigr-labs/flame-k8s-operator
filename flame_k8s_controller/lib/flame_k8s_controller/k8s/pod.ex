defmodule FlameK8sController.K8s.Pod do
  @moduledoc """
  Builds Pod manifests for FLAME runners by merging FlamePool templates
  with FlameRunner-specific configurations.
  """

  @doc """
  Creates a Pod manifest for a FLAME runner.

  Merges configuration from:
  1. FlamePool template (base configuration)
  2. FlameRunner spec (overrides and additions)
  3. FLAME-specific environment variables

  ## Arguments
  - `args` - FlameRunner resource arguments from Operator.get_args/1
  - `pool_config` - FlamePool resource configuration

  ## Returns
  Pod manifest ready to be created in Kubernetes
  """
  def manifest(args, pool_config) do
    %{
      annotations: annotations,
      labels: labels,
      name: name,
      namespace: ns,
      spec: runner_spec
    } = args

    pool_template = get_pool_template(pool_config)
    parent_ref = get_parent_ref(runner_spec)
    image = get_image(runner_spec)
    termination_grace_period_seconds = get_termination_grace_period_seconds(runner_spec)

    # Merge container specs from pool and runner
    container = merge_container_spec(pool_template, runner_spec, image, parent_ref)

    # Build pod spec
    pod_spec =
      pool_template["spec"]
      |> Map.put("containers", [container])
      |> Map.put("restartPolicy", "Never")
      |> Map.put("terminationGracePeriodSeconds", termination_grace_period_seconds)

    # Add FLAME-specific labels
    pod_labels =
      Map.merge(labels || %{}, %{
        "flame.org/runner" => "true",
        "flame.org/parent" => parent_ref["name"]
      })

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "namespace" => ns,
        "name" => name,
        "annotations" => annotations || %{},
        "labels" => pod_labels
      },
      "spec" => pod_spec
    }
  end

  @doc """
  Validates container resource consistency.

  Ensures CPU and memory requests do not exceed their corresponding limits
  when both values are provided.
  """
  @spec validate_resources(map()) :: :ok | {:error, binary()}
  def validate_resources(container) when is_map(container) do
    resources = Map.get(container, "resources", %{}) || %{}
    requests = Map.get(resources, "requests", %{}) || %{}
    limits = Map.get(resources, "limits", %{}) || %{}

    with :ok <-
           validate_request_vs_limit(
             "cpu",
             Map.get(requests, "cpu"),
             Map.get(limits, "cpu"),
             &parse_cpu_millicores/1
           ),
         :ok <-
           validate_request_vs_limit(
             "memory",
             Map.get(requests, "memory"),
             Map.get(limits, "memory"),
             &parse_memory_bytes/1
           ) do
      :ok
    end
  end

  def validate_resources(_), do: {:error, "container must be an object"}

  defp get_pool_template(pool_config) do
    get_in(pool_config, ["spec", "podTemplate"]) || %{"spec" => %{}}
  end

  defp get_parent_ref(runner_spec) do
    Map.get(runner_spec, "parentRef") || Map.get(runner_spec, :parentRef) || %{}
  end

  defp get_image(runner_spec) do
    Map.get(runner_spec, "image") || Map.get(runner_spec, :image)
  end

  defp get_termination_grace_period_seconds(runner_spec) do
    Map.get(runner_spec, "terminationGracePeriodSeconds") ||
      Map.get(runner_spec, :terminationGracePeriodSeconds) || 60
  end

  defp merge_container_spec(pool_template, runner_spec, image, parent_ref) do
    # Start with pool template container (first container)
    base_container =
      case get_in(pool_template, ["spec", "containers"]) do
        [first | _] -> first
        _ -> %{}
      end

    # Build FLAME-specific environment variables
    flame_env = build_flame_env(parent_ref, runner_spec)

    # Merge environment variables
    pool_env = Map.get(base_container, "env", [])
    runner_env = Map.get(runner_spec, "env") || Map.get(runner_spec, :env) || []
    merged_env = pool_env ++ runner_env ++ flame_env

    # Merge resources (runner can override pool)
    resources =
      case Map.get(runner_spec, "resources") || Map.get(runner_spec, :resources) do
        nil -> Map.get(base_container, "resources", %{})
        runner_resources -> runner_resources
      end

    # Build final container spec
    base_container
    |> Map.put("name", "runner")
    |> Map.put("image", image)
    |> Map.put("env", merged_env)
    |> Map.put("resources", resources)
    |> Map.put("imagePullPolicy", "IfNotPresent")
  end

  defp build_flame_env(parent_ref, runner_spec) do
    parent_name = Map.get(parent_ref, "name") || Map.get(parent_ref, :name)
    parent_namespace = Map.get(parent_ref, "namespace") || Map.get(parent_ref, :namespace)
    cookie_secret_ref =
      Map.get(runner_spec, "cookieSecretRef") || Map.get(runner_spec, :cookieSecretRef) ||
        "flame-erlang-cookie"

    [
      %{
        "name" => "FLAME_PARENT_NAME",
        "value" => parent_name
      },
      %{
        "name" => "FLAME_PARENT_NAMESPACE",
        "value" => parent_namespace
      },
      %{
        "name" => "POD_NAME",
        "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.name"}}
      },
      %{
        "name" => "POD_NAMESPACE",
        "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.namespace"}}
      },
      %{
        "name" => "POD_IP",
        "valueFrom" => %{"fieldRef" => %{"fieldPath" => "status.podIP"}}
      },
      %{
        "name" => "RELEASE_COOKIE",
        "valueFrom" => %{
          "secretKeyRef" => %{
            "name" => cookie_secret_ref,
            "key" => "cookie"
          }
        }
      }
    ]
  end

  defp validate_request_vs_limit(_resource_name, nil, _limit, _parser), do: :ok
  defp validate_request_vs_limit(_resource_name, _request, nil, _parser), do: :ok

  defp validate_request_vs_limit(resource_name, request, limit, parser) do
    with {:ok, request_value} <- parser.(request),
         {:ok, limit_value} <- parser.(limit) do
      if request_value <= limit_value do
        :ok
      else
        {:error,
         "requests.#{resource_name} (#{request}) must be less than or equal to limits.#{resource_name} (#{limit})"}
      end
    else
      :error ->
        {:error,
         "unable to parse resource quantity for #{resource_name}: request=#{inspect(request)} limit=#{inspect(limit)}"}
    end
  end

  defp parse_cpu_millicores(value) when is_integer(value), do: {:ok, value * 1000}
  defp parse_cpu_millicores(value) when is_float(value), do: {:ok, trunc(value * 1000)}

  defp parse_cpu_millicores(value) when is_binary(value) do
    normalized = String.trim(value)

    if String.ends_with?(normalized, "m") do
      milli = String.trim_trailing(normalized, "m")

      case Integer.parse(milli) do
        {parsed, ""} -> {:ok, parsed}
        _ -> :error
      end
    else
      case Float.parse(normalized) do
        {parsed, ""} -> {:ok, trunc(parsed * 1000)}
        _ -> :error
      end
    end
  end

  defp parse_cpu_millicores(_), do: :error

  defp parse_memory_bytes(value) when is_integer(value), do: {:ok, value}
  defp parse_memory_bytes(value) when is_float(value), do: {:ok, trunc(value)}

  defp parse_memory_bytes(value) when is_binary(value) do
    normalized = String.trim(value)

    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)([KMGTEP]i|[kMGTPE]|)?$/, normalized) do
      [_, num, unit] ->
        with {number, ""} <- Float.parse(num),
             {:ok, multiplier} <- memory_multiplier(unit) do
          {:ok, trunc(number * multiplier)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_memory_bytes(_), do: :error

  defp memory_multiplier(""), do: {:ok, 1}
  defp memory_multiplier("k"), do: {:ok, 1_000}
  defp memory_multiplier("M"), do: {:ok, 1_000_000}
  defp memory_multiplier("G"), do: {:ok, 1_000_000_000}
  defp memory_multiplier("T"), do: {:ok, 1_000_000_000_000}
  defp memory_multiplier("P"), do: {:ok, 1_000_000_000_000_000}
  defp memory_multiplier("E"), do: {:ok, 1_000_000_000_000_000_000}
  defp memory_multiplier("Ki"), do: {:ok, 1_024}
  defp memory_multiplier("Mi"), do: {:ok, 1_048_576}
  defp memory_multiplier("Gi"), do: {:ok, 1_073_741_824}
  defp memory_multiplier("Ti"), do: {:ok, 1_099_511_627_776}
  defp memory_multiplier("Pi"), do: {:ok, 1_125_899_906_842_624}
  defp memory_multiplier("Ei"), do: {:ok, 1_152_921_504_606_846_976}
  defp memory_multiplier(_), do: :error

end

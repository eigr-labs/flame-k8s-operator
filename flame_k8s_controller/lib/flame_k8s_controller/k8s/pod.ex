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

    # Merge container specs from pool and runner
    container = merge_container_spec(pool_template, runner_spec, image, parent_ref)

    # Build pod spec
    pod_spec =
      pool_template["spec"]
      |> Map.put("containers", [container])
      |> Map.put("restartPolicy", "Never")
      |> maybe_add_owner_reference(parent_ref)

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

  defp get_pool_template(pool_config) do
    get_in(pool_config, ["spec", "podTemplate"]) || %{"spec" => %{}}
  end

  defp get_parent_ref(runner_spec) do
    Map.get(runner_spec, "parentRef") || Map.get(runner_spec, :parentRef) || %{}
  end

  defp get_image(runner_spec) do
    Map.get(runner_spec, "image") || Map.get(runner_spec, :image)
  end

  defp merge_container_spec(pool_template, runner_spec, image, parent_ref) do
    # Start with pool template container (first container)
    base_container =
      case get_in(pool_template, ["spec", "containers"]) do
        [first | _] -> first
        _ -> %{}
      end

    # Build FLAME-specific environment variables
    flame_env = build_flame_env(parent_ref)

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

  defp build_flame_env(parent_ref) do
    parent_name = Map.get(parent_ref, "name") || Map.get(parent_ref, :name)
    parent_namespace = Map.get(parent_ref, "namespace") || Map.get(parent_ref, :namespace)

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
      }
    ]
  end

  defp maybe_add_owner_reference(pod_spec, parent_ref) do
    parent_uid = Map.get(parent_ref, "uid") || Map.get(parent_ref, :uid)

    if parent_uid do
      owner_references = [
        %{
          "apiVersion" => "v1",
          "kind" => "Pod",
          "name" => Map.get(parent_ref, "name") || Map.get(parent_ref, :name),
          "uid" => parent_uid,
          "controller" => false,
          "blockOwnerDeletion" => false
        }
      ]

      Map.put(pod_spec, "ownerReferences", owner_references)
    else
      pod_spec
    end
  end
end

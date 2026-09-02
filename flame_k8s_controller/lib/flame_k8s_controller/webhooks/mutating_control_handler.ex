defmodule FlameK8sController.Webhooks.MutatingControlHandler do
  @moduledoc """
  Mutating Webhook Handler for Postgres Kompo
  """
  use K8sWebhoox.AdmissionControl.Handler

  alias K8sWebhoox.Conn

  import K8sWebhoox.AdmissionControl.AdmissionReview

  mutate "apps/v1/deployments", conn do
    conn
    |> maybe_patch_workload()
    |> allow()
  end

  mutate "apps/v1/statefulsets", conn do
    conn
    |> maybe_patch_workload()
    |> allow()
  end

  defp is_flame_enabled?(metadata) do
    annotations = Map.get(metadata, "annotations", %{})
    Map.get(annotations, "flame.org/enabled", "false") |> to_bool()
  end

  defp patch_obj(spec, metadata) do
    annotations = Map.get(metadata, "annotations", %{})
    pool_cfg_ref = Map.get(annotations, "flame.org/pool-config-ref", "default-pool")

    timeout_to_shoot_headhead =
      Map.get(annotations, "flame.org/runner-termination-timeout", 60000)
      |> to_string()

    template = Map.get(spec, "template", %{})
    pod_spec = Map.get(template, "spec", %{})

    container =
      pod_spec
      |> Map.get("containers", [])
      |> List.first()

    base_pod =
      Jason.encode!(template)
      |> Base.encode64()

    envs =
      [
        %{"name" => "BASE_POD", "value" => base_pod},
        %{
          "name" => "POD_NAME",
          "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.name"}}
        },
        %{
          "name" => "POD_NAMESPACE",
          "valueFrom" => %{"fieldRef" => %{"fieldPath" => "metadata.namespace"}}
        },
        %{"name" => "POD_IP", "valueFrom" => %{"fieldRef" => %{"fieldPath" => "status.podIP"}}},
        %{"name" => "POD_TERMINATION_TIMEOUT", "value" => timeout_to_shoot_headhead},
        %{"name" => "FLAME_POOL_CONFIG_REF", "value" => pool_cfg_ref}
      ]
      |> maybe_put_distribution(annotations)

    updated_envs =
      case container do
        nil ->
          nil

        _ ->
          case Map.get(container, "env") do
            nil ->
              %{
                "op" => "add",
                "path" => "/spec/template/spec/containers/0/env",
                "value" => envs
              }

            existing_envs ->
              %{
                "op" => "replace",
                "path" => "/spec/template/spec/containers/0/env",
                "value" => existing_envs ++ envs
              }
          end
      end

    case updated_envs do
      nil ->
        nil

      patch ->
        [patch]
        |> Jason.encode!()
        |> Base.encode64()
    end
  end

  defp maybe_patch_workload(%Conn{request: request} = conn) do
    spec = get_in(request, ["object", "spec"]) || %{}
    metadata = get_in(spec, ["template", "metadata"]) || %{}

    if is_flame_enabled?(metadata) do
      case patch_obj(spec, metadata) do
        nil ->
          conn

        patch ->
          create_patch(conn, patch)
      end
    else
      conn
    end
  end

  defp create_patch(conn, patch_obj) do
    %Conn{} = conn

    response =
      conn.response
      |> Map.new()
      |> Map.put("patch", patch_obj)
      |> Map.put("patchType", "JSONPatch")

    %{conn | response: response}
  end

  defp maybe_put_distribution(envs, annotations) do
    auto_dist? = Map.get(annotations, "flame.org/dist-auto-config", "false") |> to_bool()

    updated_envs =
      if auto_dist? do
        case Map.get(annotations, "flame.org/otp-app", nil) do
          nil ->
            envs

          app ->
            (envs ++
               [
                 %{"name" => "RELEASE_DISTRIBUTION", "value" => "name"},
                 %{"name" => "RELEASE_NODE", "value" => "#{app}@$(POD_IP)"}
               ])
            |> List.flatten()
        end
      else
        envs
      end

    updated_envs
  end

  def to_bool("true"), do: true
  def to_bool("false"), do: false
  def to_bool(_), do: false
end

defmodule FlameK8sController.Webhooks.MutatingControlHandler do
  @moduledoc """
  Mutating Webhook Handler for Postgres Kompo
  """
  use K8sWebhoox.AdmissionControl.Handler

  alias FlameK8sController.K8s.CookieSecret
  alias FlameK8sController.K8s.WorkloadAccess
  alias K8sWebhoox.Conn

  require Logger

  import K8sWebhoox.AdmissionControl.AdmissionReview

  mutate "apps/v1/deployments", conn do
    admit_workload(conn)
  end

  mutate "apps/v1/statefulsets", conn do
    admit_workload(conn)
  end

  defp is_flame_enabled?(metadata) do
    annotations = Map.get(metadata, "annotations", %{})
    Map.get(annotations, "flame.org/enabled", "false") |> to_bool()
  end

  defp patch_obj(spec, metadata) do
    annotations = Map.get(metadata, "annotations", %{})
    pool_cfg_ref = Map.get(annotations, "flame.org/pool-config-ref", "default-pool")
    cookie_secret_ref = cookie_secret_ref(metadata)
    dist_auto_config = if(Map.get(annotations, "flame.org/dist-auto-config", "true") |> to_bool(), do: "true", else: "false")
    argocd_ignore_runner_healthcheck =
      if(
        Map.get(annotations, "flame.org/argocd-ignore-runner-healthcheck", "true")
        |> to_bool(),
        do: "true",
        else: "false"
      )

    timeout_to_shoot_headhead =
      Map.get(annotations, "flame.org/runner-termination-timeout", 60000)
      |> to_string()

    template = Map.get(spec, "template", %{})
    pod_spec = Map.get(template, "spec", %{})
    service_account_name = workload_service_account_name(pod_spec)

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
        %{
          "name" => "RELEASE_COOKIE",
          "valueFrom" => %{
            "secretKeyRef" => %{
              "name" => cookie_secret_ref,
              "key" => "cookie"
            }
          }
        },
        %{"name" => "FLAME_COOKIE_SECRET_REF", "value" => cookie_secret_ref},
        %{"name" => "FLAME_DIST_AUTO_CONFIG", "value" => dist_auto_config},
        %{
          "name" => "FLAME_ARGOCD_IGNORE_RUNNER_HEALTHCHECK",
          "value" => argocd_ignore_runner_healthcheck
        },
        %{"name" => "POD_TERMINATION_TIMEOUT", "value" => timeout_to_shoot_headhead},
        %{"name" => "FLAME_POOL_CONFIG_REF", "value" => pool_cfg_ref}
      ]
      |> maybe_put_distribution(annotations)

    service_account_patch =
      if Map.get(pod_spec, "serviceAccountName") || Map.get(pod_spec, :serviceAccountName) do
        nil
      else
        %{
          "op" => "add",
          "path" => "/spec/template/spec/serviceAccountName",
          "value" => service_account_name
        }
      end

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

    patches = Enum.filter([service_account_patch, updated_envs], &(!is_nil(&1)))

    case patches do
      [] ->
        nil

      _ ->
        patches
        |> Jason.encode!()
        |> Base.encode64()
    end
  end

  defp admit_workload(%Conn{request: request} = conn) do
    spec = get_in(request, ["object", "spec"]) || %{}
    metadata = get_in(spec, ["template", "metadata"]) || %{}
    namespace = workload_namespace(request)

    Logger.warning("Handling FLAME webhook admission",
      resource: get_in(request, ["resource", "resource"]),
      namespace: namespace,
      flame_enabled: is_flame_enabled?(metadata)
    )

    if is_flame_enabled?(metadata) do
       service_account_name = workload_service_account_name(get_in(spec, ["template", "spec"]) || %{})

       with :ok <- CookieSecret.ensure_namespace_secret(namespace, cookie_secret_ref(metadata)),
         :ok <- WorkloadAccess.ensure_namespace_access(namespace, service_account_name),
           patch when not is_nil(patch) <- patch_obj(spec, metadata) do
        Logger.warning("Generated FLAME mutating patch", namespace: namespace)

        conn
        |> create_patch(patch)
        |> allow()
      else
        nil ->
          allow(conn)

        {:error, reason} ->
          deny(conn, 500, reason)
      end
    else
      allow(conn)
    end
  end

  defp cookie_secret_ref(metadata) do
    metadata
    |> Map.get("annotations", %{})
    |> Map.get("flame.org/cookie-secret-ref", "flame-erlang-cookie")
  end

  defp workload_namespace(request) do
    request["namespace"] || get_in(request, ["object", "metadata", "namespace"]) || "default"
  end

  defp workload_service_account_name(pod_spec) do
    Map.get(pod_spec, "serviceAccountName") ||
      Map.get(pod_spec, :serviceAccountName) ||
      WorkloadAccess.default_service_account_name()
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
    auto_dist? = Map.get(annotations, "flame.org/dist-auto-config", "true") |> to_bool()

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

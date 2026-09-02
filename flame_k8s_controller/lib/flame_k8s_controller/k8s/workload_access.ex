defmodule FlameK8sController.K8s.WorkloadAccess do
  @moduledoc """
  Ensures workload namespaces have the RBAC required for FLAME-enabled apps.
  """

  alias FlameK8sController.K8sConn

  require Logger

  @field_manager "flame-k8s-controller"
  @default_service_account_name "flame-workload"
  @default_role_name "flame-workload"
  @k8s_env Mix.env()

  @spec ensure_namespace_access(binary(), binary(), keyword()) :: :ok | {:error, binary()}
  def ensure_namespace_access(target_namespace, service_account_name \\ @default_service_account_name, opts \\ []) do
    cond do
      not management_enabled?() ->
        :ok

      blank?(target_namespace) ->
        {:error, "Missing target namespace for FLAME workload access"}

      blank?(service_account_name) ->
        {:error, "Missing service account name for FLAME workload access"}

      true ->
        conn = Keyword.get(opts, :conn) || K8sConn.get!(@k8s_env)

        with :ok <- apply_service_account(conn, target_namespace, service_account_name),
             :ok <- apply_role(conn, target_namespace),
             :ok <- apply_role_binding(conn, target_namespace, service_account_name) do
          :ok
        else
          {:error, reason} = error ->
            Logger.error(
              "Failed to ensure FLAME workload access in namespace #{target_namespace} for service account #{service_account_name}: #{reason}"
            )

            error
        end
    end
  end

  def default_service_account_name, do: @default_service_account_name

  defp management_enabled? do
    Application.get_env(:flame_k8s_controller, :workload_access_management_enabled, true)
  end

  defp apply_service_account(conn, namespace, service_account_name) do
    manifest = %{
      "apiVersion" => "v1",
      "kind" => "ServiceAccount",
      "metadata" => %{
        "name" => service_account_name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => @field_manager,
          "flame.org/workload-access" => "true"
        }
      }
    }

    apply_manifest(conn, manifest)
  end

  defp apply_role(conn, namespace) do
    manifest = %{
      "apiVersion" => "rbac.authorization.k8s.io/v1",
      "kind" => "Role",
      "metadata" => %{
        "name" => @default_role_name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => @field_manager,
          "flame.org/workload-access" => "true"
        }
      },
      "rules" => [
        %{
          "apiGroups" => ["flame.org"],
          "resources" => ["flamerunners"],
          "verbs" => ["create", "get", "list", "watch", "delete"]
        },
        %{
          "apiGroups" => [""],
          "resources" => ["pods"],
          "verbs" => ["get"]
        }
      ]
    }

    apply_manifest(conn, manifest)
  end

  defp apply_role_binding(conn, namespace, service_account_name) do
    manifest = %{
      "apiVersion" => "rbac.authorization.k8s.io/v1",
      "kind" => "RoleBinding",
      "metadata" => %{
        "name" => @default_role_name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => @field_manager,
          "flame.org/workload-access" => "true"
        }
      },
      "roleRef" => %{
        "apiGroup" => "rbac.authorization.k8s.io",
        "kind" => "Role",
        "name" => @default_role_name
      },
      "subjects" => [
        %{
          "kind" => "ServiceAccount",
          "name" => service_account_name,
          "namespace" => namespace
        }
      ]
    }

    apply_manifest(conn, manifest)
  end

  defp apply_manifest(conn, manifest) do
    case K8s.Client.apply(manifest, field_manager: @field_manager, force: true)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _resource} -> :ok
      {:error, reason} -> {:error, "Kubernetes apply failed: #{inspect(reason)}"}
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
end

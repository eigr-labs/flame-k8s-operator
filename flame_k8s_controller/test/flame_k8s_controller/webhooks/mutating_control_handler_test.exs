defmodule FlameK8sController.Webhooks.MutatingControlHandlerTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.Webhooks.MutatingControlHandler
  alias K8sWebhoox.Conn

  describe "handle/2" do
    test "adds flame env patch for deployments" do
      conn =
        admission_conn("deployments", %{
          "template" => %{
            "metadata" => %{"annotations" => %{"flame.org/enabled" => "true", "flame.org/otp-app" => "my_app_release_name"}},
            "spec" => %{
              "containers" => [
                %{
                  "name" => "app",
                  "image" => "ghcr.io/example/app:latest",
                  "env" => [%{"name" => "EXISTING_ENV", "value" => "1"}]
                }
              ]
            }
          }
        })

      result = MutatingControlHandler.handle(conn, nil)

      assert result.response["allowed"] == true
      assert is_binary(result.response["patch"])
      assert result.response["patchType"] == "JSONPatch"

      patch_ops = decode_patch(result.response["patch"])

      service_account_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/serviceAccountName"))
      env_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/containers/0/env"))

      assert service_account_patch["op"] == "add"
      assert service_account_patch["value"] == "flame-workload"
      assert env_patch["op"] == "replace"
      assert contains_env_name?(env_patch["value"], "FLAME_POOL_CONFIG_REF")
      assert contains_env_name?(env_patch["value"], "BASE_POD")
      assert env_value(env_patch["value"], "FLAME_ARGOCD_IGNORE_RUNNER_HEALTHCHECK") == "true"
      assert contains_env_name?(env_patch["value"], "RELEASE_DISTRIBUTION")
      assert contains_env_name?(env_patch["value"], "RELEASE_NODE")
    end

    test "respects explicit disable of dist auto config" do
      conn =
        admission_conn("deployments", %{
          "template" => %{
            "metadata" => %{"annotations" => %{"flame.org/enabled" => "true", "flame.org/otp-app" => "my_app_release_name", "flame.org/dist-auto-config" => "false"}},
            "spec" => %{
              "containers" => [
                %{
                  "name" => "app",
                  "image" => "ghcr.io/example/app:latest",
                  "env" => [%{"name" => "EXISTING_ENV", "value" => "1"}]
                }
              ]
            }
          }
        })

      result = MutatingControlHandler.handle(conn, nil)
      patch_ops = decode_patch(result.response["patch"])
      env_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/containers/0/env"))

      refute contains_env_name?(env_patch["value"], "RELEASE_DISTRIBUTION")
      refute contains_env_name?(env_patch["value"], "RELEASE_NODE")
    end

    test "allows opt-out of default argocd ignore-healthcheck for runners" do
      conn =
        admission_conn("deployments", %{
          "template" => %{
            "metadata" => %{
              "annotations" => %{
                "flame.org/enabled" => "true",
                "flame.org/argocd-ignore-runner-healthcheck" => "false"
              }
            },
            "spec" => %{
              "containers" => [
                %{
                  "name" => "app",
                  "image" => "ghcr.io/example/app:latest"
                }
              ]
            }
          }
        })

      result = MutatingControlHandler.handle(conn, nil)
      patch_ops = decode_patch(result.response["patch"])
      env_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/containers/0/env"))

      assert env_value(env_patch["value"], "FLAME_ARGOCD_IGNORE_RUNNER_HEALTHCHECK") == "false"
    end

    test "adds flame env patch for statefulsets" do
      conn =
        admission_conn("statefulsets", %{
          "template" => %{
            "metadata" => %{"annotations" => %{"flame.org/enabled" => "true"}},
            "spec" => %{
              "containers" => [
                %{
                  "name" => "app",
                  "image" => "ghcr.io/example/app:latest"
                }
              ]
            }
          }
        })

      result = MutatingControlHandler.handle(conn, nil)

      assert result.response["allowed"] == true
      assert is_binary(result.response["patch"])

      patch_ops = decode_patch(result.response["patch"])
      service_account_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/serviceAccountName"))
      env_patch = Enum.find(patch_ops, &(&1["path"] == "/spec/template/spec/containers/0/env"))

      assert service_account_patch["op"] == "add"
      assert service_account_patch["value"] == "flame-workload"
      assert env_patch["op"] == "add"
      assert contains_env_name?(env_patch["value"], "POD_NAME")
    end

    test "does not patch when flame is not enabled" do
      conn =
        admission_conn("deployments", %{
          "template" => %{
            "metadata" => %{"annotations" => %{}},
            "spec" => %{"containers" => [%{"name" => "app", "image" => "nginx"}]}
          }
        })

      result = MutatingControlHandler.handle(conn, nil)

      assert result.response["allowed"] == true
      refute Map.has_key?(result.response, "patch")
      refute Map.has_key?(result.response, "patchType")
    end
  end

  defp admission_conn(resource, object_spec) do
    %Conn{
      api_version: "admission.k8s.io/v1",
      kind: "AdmissionReview",
      assigns: %{admission_control_handler: [webhook_type: :mutating]},
      request: %{
        "uid" => "uid-1",
        "resource" => %{"group" => "apps", "version" => "v1", "resource" => resource},
        "object" => %{"spec" => object_spec}
      },
      response: %{"uid" => "uid-1"}
    }
  end

  defp decode_patch(encoded_patch) do
    encoded_patch
    |> Base.decode64!()
    |> Jason.decode!()
  end

  defp contains_env_name?(env_entries, name) do
    Enum.any?(env_entries, fn entry -> entry["name"] == name end)
  end

  defp env_value(env_entries, name) do
    env_entries
    |> Enum.find(fn entry -> entry["name"] == name end)
    |> case do
      nil -> nil
      entry -> entry["value"]
    end
  end
end

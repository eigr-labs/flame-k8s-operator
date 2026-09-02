defmodule FlameK8sController.Webhooks.MutatingControlHandlerTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.Webhooks.MutatingControlHandler
  alias K8sWebhoox.Conn

  describe "handle/2" do
    test "adds flame env patch for deployments" do
      conn =
        admission_conn("deployments", %{
          "template" => %{
            "metadata" => %{"annotations" => %{"flame.org/enabled" => "true"}},
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

      [patch_op] = decode_patch(result.response["patch"])
      assert patch_op["op"] == "replace"
      assert patch_op["path"] == "/spec/template/spec/containers/0/env"
      assert contains_env_name?(patch_op["value"], "FLAME_POOL_CONFIG_REF")
      assert contains_env_name?(patch_op["value"], "BASE_POD")
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

      [patch_op] = decode_patch(result.response["patch"])
      assert patch_op["op"] == "add"
      assert patch_op["path"] == "/spec/template/spec/containers/0/env"
      assert contains_env_name?(patch_op["value"], "POD_NAME")
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
end

defmodule FlameK8sController.K8s.PodTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.K8s.Pod

  describe "manifest/2" do
    test "propagates terminationGracePeriodSeconds from runner spec" do
      args = base_args(%{"terminationGracePeriodSeconds" => 25})
      manifest = Pod.manifest(args, pool_config())

      assert get_in(manifest, ["spec", "terminationGracePeriodSeconds"]) == 25
    end

    test "uses default terminationGracePeriodSeconds when runner spec does not define it" do
      args = base_args(%{})
      manifest = Pod.manifest(args, pool_config())

      assert get_in(manifest, ["spec", "terminationGracePeriodSeconds"]) == 60
    end

    test "includes completion-related base metadata" do
      args = base_args(%{"terminationGracePeriodSeconds" => 10})
      manifest = Pod.manifest(args, pool_config())
      env = get_in(manifest, ["spec", "containers", Access.at(0), "env"]) || []

      assert get_in(manifest, ["metadata", "labels", "flame.org/runner"]) == "true"
      assert get_in(manifest, ["metadata", "labels", "flame.org/parent"]) == "app-parent"
      assert Enum.any?(env, &(&1["name"] == "RELEASE_DISTRIBUTION" and &1["value"] == "name"))
      assert Enum.any?(env, fn env_var ->
               env_var["name"] == "RELEASE_NODE" and env_var["value"] == "$(FLAME_NODE_BASE)@$(POD_IP)"
             end)
    end

    test "does not inject distribution env when FLAME_DIST_AUTO_CONFIG=false" do
      args =
        base_args(%{
          "env" => [
            %{"name" => "EXTRA_ENV", "value" => "1"},
            %{"name" => "FLAME_DIST_AUTO_CONFIG", "value" => "false"}
          ]
        })

      manifest = Pod.manifest(args, pool_config())
      env = get_in(manifest, ["spec", "containers", Access.at(0), "env"]) || []

      refute Enum.any?(env, &(&1["name"] == "RELEASE_DISTRIBUTION"))
      refute Enum.any?(env, &(&1["name"] == "RELEASE_NODE"))
    end
  end

  describe "validate_resources/1" do
    test "returns ok when requests are less than or equal to limits" do
      container = %{
        "resources" => %{
          "requests" => %{"cpu" => "100m", "memory" => "128Mi"},
          "limits" => %{"cpu" => "200m", "memory" => "256Mi"}
        }
      }

      assert :ok = Pod.validate_resources(container)
    end

    test "returns error when requests exceed limits" do
      container = %{
        "resources" => %{
          "requests" => %{"cpu" => "300m", "memory" => "512Mi"},
          "limits" => %{"cpu" => "200m", "memory" => "256Mi"}
        }
      }

      assert {:error, message} = Pod.validate_resources(container)
      assert message =~ "requests.cpu"
    end
  end

  defp base_args(extra_spec) do
    %{
      annotations: %{"owner" => "flame"},
      labels: %{"app" => "runner"},
      name: "runner-1",
      namespace: "default",
      spec:
        Map.merge(
          %{
            "parentRef" => %{
              "name" => "app-parent",
              "namespace" => "default",
              "uid" => "parent-uid-123"
            },
            "image" => "ghcr.io/example/runner:latest",
            "env" => [%{"name" => "EXTRA_ENV", "value" => "1"}]
          },
          extra_spec
        )
    }
  end

  defp pool_config do
    %{
      "spec" => %{
        "podTemplate" => %{
          "spec" => %{
            "containers" => [
              %{
                "name" => "runner",
                "env" => [%{"name" => "POOL_ENV", "value" => "pool"}],
                "resources" => %{
                  "requests" => %{"cpu" => "100m", "memory" => "128Mi"}
                }
              }
            ]
          }
        }
      }
    }
  end
end

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

    test "includes completion-related base metadata and owner reference when parent UID exists" do
      args = base_args(%{"terminationGracePeriodSeconds" => 10})
      manifest = Pod.manifest(args, pool_config())

      assert get_in(manifest, ["metadata", "labels", "flame.org/runner"]) == "true"
      assert get_in(manifest, ["metadata", "labels", "flame.org/parent"]) == "app-parent"

      assert get_in(manifest, ["spec", "ownerReferences", Access.at(0), "uid"]) == "parent-uid-123"
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

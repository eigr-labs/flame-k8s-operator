defmodule FlameK8sController.Handler.FlamePoolHandlerTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.Handler.FlamePoolHandler

  describe "call/2" do
    test "marks pool as ready when configuration is valid" do
      axn = base_axn(valid_pool_resource(), :add)
      result = FlamePoolHandler.call(axn, nil)

      assert result.status["observedGeneration"] == 3
      assert result.status["phase"] == "Ready"
      assert result.status["reason"] == "ConfigurationValid"
      assert result.status["message"] == "FlamePool configuration is valid"
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "Ready" and &1["status"] == "True"))
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "TemplateValid" and &1["status"] == "True"))
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "SchedulingResolved" and &1["status"] == "True"))
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "SchedulingInfrastructure"))
      assert is_map(result.status["resolvedScheduling"])
      assert get_in(result.status, ["resolvedScheduling", "generated", "provider"]) == "generic"
      assert is_map(result.status["schedulingFeedback"])
      assert Map.has_key?(result.status["schedulingFeedback"], "matchingNodesNames")
      assert is_binary(result.status["schedulingFeedback"]["matchingNodesNames"])
      assert length(result.events) == 1
    end

    test "marks pool as not ready when containers are missing" do
      invalid_resource =
        put_in(valid_pool_resource(), ["spec", "podTemplate", "spec", "containers"], [])

      axn = base_axn(invalid_resource, :modify)
      result = FlamePoolHandler.call(axn, nil)

      assert result.status["observedGeneration"] == 3
      assert result.status["phase"] == "Invalid"
      assert result.status["reason"] == "ConfigurationInvalid"
      assert result.status["message"] =~ "At least one container"
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "Ready" and &1["status"] == "False"))
      assert Enum.any?(result.status["conditions"], &(&1["type"] == "TemplateValid" and &1["status"] == "False"))
      assert length(result.events) == 1
    end

    test "marks pool as invalid when container requests exceed limits" do
      invalid_resource =
        valid_pool_resource()
        |> put_in(
          ["spec", "podTemplate", "spec", "containers", Access.at(0), "resources"],
          %{
            "requests" => %{"cpu" => "300m", "memory" => "512Mi"},
            "limits" => %{"cpu" => "200m", "memory" => "256Mi"}
          }
        )

      axn = base_axn(invalid_resource, :modify)
      result = FlamePoolHandler.call(axn, nil)

      assert result.status["phase"] == "Invalid"
      assert result.status["reason"] == "ConfigurationInvalid"
      assert result.status["message"] =~ "Invalid resources in podTemplate.spec.containers[0]"
      assert result.status["message"] =~ "requests.cpu"
    end

    test "marks pool as invalid when scheduling abstraction has unsupported value" do
      invalid_resource =
        valid_pool_resource()
        |> put_in(["spec", "scheduling"], %{"lifecycle" => "preemptible"})

      axn = base_axn(invalid_resource, :modify)
      result = FlamePoolHandler.call(axn, nil)

      assert result.status["phase"] == "Invalid"
      assert result.status["reason"] == "ConfigurationInvalid"
      assert result.status["message"] =~ "spec.scheduling.lifecycle"
      assert result.status["message"] =~ "Allowed values"
    end

    test "marks pool as invalid when provider is unsupported" do
      invalid_resource =
        valid_pool_resource()
        |> put_in(["spec", "scheduling"], %{"provider" => "eks"})

      axn = base_axn(invalid_resource, :modify)
      result = FlamePoolHandler.call(axn, nil)

      assert result.status["phase"] == "Invalid"
      assert result.status["message"] =~ "spec.scheduling.provider"
      assert result.status["message"] =~ "Allowed values: generic, karpenter"
    end

  end

  describe "sanitize_conditions/1" do
    test "keeps only schema-supported condition fields" do
      input = [
        %{
          "type" => "Ready",
          "status" => "True",
          "lastTransitionTime" => "2026-09-02T00:00:00Z",
          "reason" => "Ok",
          "message" => "all good",
          "observedGeneration" => 1,
          "lastProbeTime" => "2026-09-02T00:00:00Z"
        }
      ]

      assert [condition] = FlamePoolHandler.sanitize_conditions(input)
      assert condition["type"] == "Ready"
      assert condition["status"] == "True"
      assert condition["lastTransitionTime"] == "2026-09-02T00:00:00Z"
      assert condition["reason"] == "Ok"
      assert condition["message"] == "all good"
      refute Map.has_key?(condition, "observedGeneration")
      refute Map.has_key?(condition, "lastProbeTime")
    end
  end

  describe "format_matching_nodes_names_for_status/2" do
    test "returns empty bracket list for no nodes" do
      formatted = FlamePoolHandler.format_matching_nodes_names_for_status([])

      assert formatted.matching_nodes == 0
      assert formatted.matching_nodes_names == "[]"
    end

    test "returns full list when node count is within cap" do
      formatted = FlamePoolHandler.format_matching_nodes_names_for_status(["node-a", "node-b", "node-c"])

      assert formatted.matching_nodes == 3
      assert formatted.matching_nodes_names == "[node-a,node-b,node-c]"
    end

    test "truncates list and appends ellipsis when node count exceeds cap" do
      formatted =
        FlamePoolHandler.format_matching_nodes_names_for_status([
          "node-a",
          "node-b",
          "node-c",
          "node-d",
          "node-e"
        ])

      assert formatted.matching_nodes == 5
      assert formatted.matching_nodes_names == "[node-a,node-b,node-c,...]"
    end

    test "uses default cap when invalid max is provided" do
      formatted =
        FlamePoolHandler.format_matching_nodes_names_for_status([
          "node-a",
          "node-b",
          "node-c",
          "node-d"
        ], 0)

      assert formatted.matching_nodes == 4
      assert formatted.matching_nodes_names == "[node-a,node-b,node-c,...]"
    end
  end

  defp base_axn(resource, action) do
    Bonny.Axn.new!(
      conn: nil,
      resource: resource,
      action: action
    )
  end

  defp valid_pool_resource do
    %{
      "apiVersion" => "flame.org/v1",
      "kind" => "FlamePool",
      "metadata" => %{
        "name" => "default-pool",
        "namespace" => "default",
        "uid" => "pool-uid-1",
        "generation" => 3
      },
      "spec" => %{
        "podTemplate" => %{
          "spec" => %{
            "containers" => [
              %{
                "name" => "runner",
                "image" => "ghcr.io/example/runner:latest"
              }
            ]
          }
        }
      }
    }
  end
end

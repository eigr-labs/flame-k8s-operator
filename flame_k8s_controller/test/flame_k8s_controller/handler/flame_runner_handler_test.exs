defmodule FlameK8sController.Handler.FlameRunnerHandlerTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.Handler.FlameRunnerHandler

  describe "call/2" do
    test "marks runner as failed when required image is missing" do
      resource =
        valid_runner_resource()
        |> update_in(["spec"], &Map.delete(&1, "image"))

      axn = base_axn(resource, :add)
      result = FlameRunnerHandler.call(axn, nil)

      assert result.status["phase"] == "Failed"
      assert result.status["message"] =~ "Missing required field: image"
      assert [condition] = result.status["conditions"]
      assert condition["type"] == "Failed"
      assert condition["status"] == "False"
      assert length(result.events) == 1
    end

    test "falls back to minimal pool config when pool lookup fails" do
      axn = base_axn(valid_runner_resource(), :add)
      result = FlameRunnerHandler.call(axn, nil)

      assert result.status["phase"] == "Pending"
      assert result.status["podName"] == "runner-123"
      assert map_size(result.descendants) == 1

      {_, {_, pod_manifest}} = Enum.at(result.descendants, 0)
      assert get_in(pod_manifest, ["kind"]) == "Pod"
      assert get_in(pod_manifest, ["spec", "terminationGracePeriodSeconds"]) == 60
      assert get_in(pod_manifest, ["spec", "containers", Access.at(0), "resources", "requests", "cpu"]) == "50m"
      assert length(result.events) == 1
    end
  end

  describe "build_status_from_pod/2" do
    test "maps running pod status" do
      status =
        FlameRunnerHandler.build_status_from_pod(
          runner_resource_with_generation(7),
          %{
            "name" => "runner-123",
            "phase" => "Running",
            "podIP" => "10.0.0.2",
            "startTime" => "2026-09-01T10:00:00Z",
            "conditions" => [%{"type" => "Ready", "status" => "True"}]
          }
        )

      assert status["phase"] == "Running"
      assert status["podIP"] == "10.0.0.2"
      assert status["startTime"] == "2026-09-01T10:00:00Z"
      refute Map.has_key?(status, "completionTime")
    end

    test "maps succeeded pod status with completion time" do
      status =
        FlameRunnerHandler.build_status_from_pod(
          runner_resource_with_generation(8),
          %{
            "name" => "runner-123",
            "phase" => "Succeeded",
            "podIP" => "10.0.0.3",
            "startTime" => "2026-09-01T10:00:00Z",
            "completionTime" => "2026-09-01T10:03:00Z",
            "conditions" => [%{"type" => "Ready", "status" => "False"}]
          }
        )

      assert status["phase"] == "Succeeded"
      assert status["completionTime"] == "2026-09-01T10:03:00Z"
    end

    test "maps failed pod status with completion time" do
      status =
        FlameRunnerHandler.build_status_from_pod(
          runner_resource_with_generation(9),
          %{
            "name" => "runner-123",
            "phase" => "Failed",
            "podIP" => "10.0.0.4",
            "startTime" => "2026-09-01T10:00:00Z",
            "completionTime" => "2026-09-01T10:01:00Z",
            "conditions" => [%{"type" => "ContainersReady", "status" => "False"}]
          }
        )

      assert status["phase"] == "Failed"
      assert status["completionTime"] == "2026-09-01T10:01:00Z"
      assert status["observedGeneration"] == 9
    end
  end

  defp base_axn(resource, action) do
    Bonny.Axn.new!(
      conn: nil,
      resource: resource,
      action: action
    )
  end

  defp valid_runner_resource do
    %{
      "apiVersion" => "flame.org/v1",
      "kind" => "FlameRunner",
      "metadata" => %{
        "name" => "runner-123",
        "namespace" => "default",
        "uid" => "runner-uid-123",
        "generation" => 5
      },
      "spec" => %{
        "parentRef" => %{
          "name" => "parent-app",
          "namespace" => "default",
          "uid" => "parent-uid-123"
        },
        "image" => "ghcr.io/example/runner:latest"
      }
    }
  end

  defp runner_resource_with_generation(generation) do
    valid_runner_resource()
    |> put_in(["metadata", "generation"], generation)
  end
end

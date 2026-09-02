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

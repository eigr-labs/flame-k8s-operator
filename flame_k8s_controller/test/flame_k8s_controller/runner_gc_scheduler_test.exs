defmodule FlameK8sController.RunnerGcSchedulerTest do
  use ExUnit.Case, async: true

  alias FlameK8sController.RunnerGcScheduler

  describe "stale_pending_runner?/2" do
    test "returns true for old pending runner" do
      old_timestamp = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      runner = %{
        "metadata" => %{"creationTimestamp" => old_timestamp},
        "status" => %{"phase" => "Pending"}
      }

      assert RunnerGcScheduler.stale_pending_runner?(runner, 3600)
    end

    test "returns true for old not provisioned runner" do
      old_timestamp = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      runner = %{
        "metadata" => %{"creationTimestamp" => old_timestamp},
        "status" => %{"phase" => "NotProvisioned"}
      }

      assert RunnerGcScheduler.stale_pending_runner?(runner, 3600)
    end

    test "returns false for recent pending runner" do
      recent_timestamp = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      runner = %{
        "metadata" => %{"creationTimestamp" => recent_timestamp},
        "status" => %{"phase" => "Pending"}
      }

      refute RunnerGcScheduler.stale_pending_runner?(runner, 3600)
    end

    test "returns false for non pending phases" do
      old_timestamp = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      runner = %{
        "metadata" => %{"creationTimestamp" => old_timestamp},
        "status" => %{"phase" => "Running"}
      }

      refute RunnerGcScheduler.stale_pending_runner?(runner, 3600)
    end

    test "returns false for invalid timestamp" do
      runner = %{
        "metadata" => %{"creationTimestamp" => "invalid"},
        "status" => %{"phase" => "Pending"}
      }

      refute RunnerGcScheduler.stale_pending_runner?(runner, 3600)
    end
  end
end

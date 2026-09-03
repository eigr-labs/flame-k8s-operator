defmodule FlameExampleTest do
  use ExUnit.Case
  doctest FlameExample

  alias FlameExample.DemoRunner

  test "run_demo/0 returns FLAME payload" do
    result = FlameExample.run_demo()

    assert is_map(result)
    assert result.message == "hello from FLAME"
    assert is_atom(result.node)
    assert Map.has_key?(result, :parent)
  end

  test "DemoRunner.init/1 keeps configured timings and schedules first run" do
    assert {:ok, state} = DemoRunner.init(interval: 25, initial_delay: 0)

    assert state.interval == 25
    assert state.initial_delay == 0
    assert_receive :run_demo, 50
  end

  test "DemoRunner.handle_info/2 schedules the next run and keeps state" do
    state = %{interval: 10, initial_delay: 0}

    assert {:noreply, returned_state} = DemoRunner.handle_info(:run_demo, state)
    assert returned_state == state
    assert_receive :run_demo, 50
  end
end

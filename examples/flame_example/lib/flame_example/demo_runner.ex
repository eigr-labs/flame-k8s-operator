defmodule FlameExample.DemoRunner do
  @moduledoc """
  Runs a small FLAME call so the example application exercises the backend.
  """

  use GenServer

  require Logger

  @default_interval 30_000
  @default_initial_delay 3_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @default_interval),
      initial_delay: Keyword.get(opts, :initial_delay, @default_initial_delay)
    }

    Process.send_after(self(), :run_demo, state.initial_delay)
    {:ok, state}
  end

  @impl true
  def handle_info(:run_demo, state) do
    case run_demo_safe() do
      {:error, reason} ->
        Logger.error("FLAME demo call failed: #{inspect(reason)}")

      result ->
        Logger.info("FLAME demo call completed: #{inspect(result)}")
    end

    Process.send_after(self(), :run_demo, state.interval)
    {:noreply, state}
  end

  defp run_demo_safe do
    FlameExample.run_demo()
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    :exit, reason ->
      {:error, reason}
    kind, reason ->
      {:error, {kind, reason}}
  end
end

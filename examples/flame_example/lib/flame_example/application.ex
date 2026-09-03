defmodule FlameExample.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {FLAME.Pool,
       name: FlameExample.RunnerPool,
       min: 0,
       max: 2,
       max_concurrency: 10,
       idle_shutdown_after: 30_000}
    ]

    children =
      case FLAME.Parent.get() do
        nil -> children ++ [{FlameExample.DemoRunner, interval: 30_000, initial_delay: 10_000}]
        _parent -> children
      end

    opts = [strategy: :one_for_one, name: FlameExample.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule FlameExample do
  @moduledoc """
  Small helper module for the example application.
  """

  @pool_name FlameExample.RunnerPool

  def run_demo do
    FLAME.call(@pool_name, fn ->
      %{
        node: Node.self(),
        parent: FLAME.Parent.get(),
        message: "hello from FLAME"
      }
    end,
      timeout: 60_000
    )
  end
end

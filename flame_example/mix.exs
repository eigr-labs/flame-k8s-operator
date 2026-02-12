defmodule FlameExample.MixProject do
  use Mix.Project

  @app :flame_example
  @version "0.1.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FlameExample.Application, []}
    ]
  end

  defp deps do
    [
      {:bakeware, ">= 0.0.0", runtime: false},
      {:bandit, "~> 1.1"},
      {:flame, "~> 0.1.6"},
      {:flame_k8s, path: "../flame_k8s"}
    ]
  end

  defp releases do
    [
      flame_example: [
        include_executables_for: [:unix],
        applications: [flame_example: :permanent],
        steps: [
          :assemble,
          &Bakeware.assemble/1
        ],
        bakeware: [compression_level: 19]
      ]
    ]
  end
end

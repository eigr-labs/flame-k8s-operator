defmodule FlameK8sController.MixProject do
  use Mix.Project

  @app :flame_k8s_controller
  @version "0.1.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FlameK8sController.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  defp deps do
    [
      {:bakeware, ">= 0.0.0", runtime: false},
      {:bandit, "~> 1.1"},
      {:bonny, "~> 1.4"},
      {:castore, "~> 1.0"},
      {:k8s_webhoox, "~> 0.2"}
    ]
  end

  defp releases do
    [
      flame_k8s_controller: [
        include_executables_for: [:unix],
        applications: [flame_k8s_controller: :permanent],
        steps: [
          :assemble,
          &Bakeware.assemble/1
        ],
        bakeware: [compression_level: 19]
      ]
    ]
  end
end

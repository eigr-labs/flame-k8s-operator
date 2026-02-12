defmodule FLAME.K8s.MixProject do
  use Mix.Project

  @app :flame_k8s
  @version "0.1.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:flame, "~> 0.4.0 or ~> 0.5.0"},
      {:k8s, "~> 2.8"},
      {:req, "~> 0.5.0"}
    ]
  end
end

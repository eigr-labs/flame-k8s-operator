defmodule FLAME.K8s.MixProject do
  use Mix.Project

  @app :flame_k8s
  @version "0.1.4"
  @source_url "https://github.com/eigr-labs/flame-k8s-operator/tree/main/flame_k8s"
  @description "Kubernetes backend integration for FLAME"

  def project do
    [
      app: @app,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "FLAME Kubernetes Backend",
      package: package(),
      source_url: @source_url,
      docs: docs()
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
      {:req, "~> 0.7"},
      {:ex_doc, "~> 0.40", only: [:dev, :docs], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "CHANGELOG.md",
        "guides/getting_started/overview.md",
        "guides/getting_started/quickstart.md",
        "guides/getting_started/backend_setup.md",
        "guides/operator/installation.md",
        "guides/operator/how_it_works.md",
        "guides/operator/features.md",
        "guides/operator/operations.md",
        "guides/advanced/deployment_generator.md"
      ],
      groups_for_modules: [
        "Backend": [
          FLAME.K8s,
          FLAME.K8sBackend
        ],
        "Mix Tasks": [
          Mix.Tasks.Flame.Gen.Deployment
        ]
      ],
      groups_for_extras: [
        "Getting Started": ~r"^guides/getting_started/",
        Operator: ~r"^guides/operator/",
        Advanced: ~r"^guides/advanced/"
      ]
    ]
  end
end

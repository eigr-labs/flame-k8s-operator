defmodule Mix.Tasks.Flame.Gen.Deployment do
  @moduledoc """
  Generates a FLAME-ready Kubernetes Deployment manifest.
  """

  use Mix.Task

  @shortdoc "Generate a FLAME-enabled Deployment manifest"

  @default_annotations %{
    "flame.org/enabled" => "true",
    "flame.org/pool-config-ref" => "default-pool",
    "flame.org/dist-auto-config" => "true",
    "flame.org/otp-app" => "flame_app",
    "flame.org/runner-termination-timeout" => "60000",
    "flame.org/cookie-secret-ref" => "flame-erlang-cookie"
  }

  @default_resources %{
    "limits" => %{"cpu" => "200m", "memory" => "200Mi"},
    "requests" => %{"cpu" => "200m", "memory" => "200Mi"}
  }

  @switches [
    name: :string,
    namespace: :string,
    image: :string,
    replicas: :integer,
    output: :string,
    pool_config_ref: :string,
    otp_app: :string,
    cookie_secret_ref: :string,
    runner_termination_timeout: :integer,
    app_label: :string,
    container_name: :string
  ]

  @aliases [n: :name, ns: :namespace, i: :image, o: :output]

  @default_opts [
    name: "flame-parent-example",
    namespace: "default",
    image: nil,
    replicas: 1,
    output: nil,
    pool_config_ref: "default-pool",
    otp_app: "flame_app",
    cookie_secret_ref: "flame-erlang-cookie",
    runner_termination_timeout: 60000,
    app_label: nil,
    container_name: nil
  ]

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    {opts, remaining, invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if remaining != [] or invalid != [] do
      Mix.raise("invalid arguments. Use --help for usage details")
    end

    opts = @default_opts |> Keyword.merge(opts) |> normalize_opts()

    manifest = render_manifest(opts)

    case opts[:output] do
      nil ->
        Mix.Shell.IO.info(manifest)

      output_path ->
        File.mkdir_p!(Path.dirname(output_path))
        File.write!(output_path, manifest)
        Mix.Shell.IO.info("Wrote deployment manifest to #{output_path}")
    end
  end

  defp normalize_opts(opts) do
    name = Keyword.fetch!(opts, :name)
    container_name = Keyword.get(opts, :container_name) || name
    app_label = Keyword.get(opts, :app_label) || name
    image = Keyword.get(opts, :image)

    if is_nil(image) or image == "" do
      Mix.raise("--image is required, for example: mix flame.gen.deployment --image ghcr.io/example/app:latest")
    end

    opts
    |> Keyword.put(:container_name, container_name)
    |> Keyword.put(:app_label, app_label)
    |> Keyword.put(:image, image)
    |> Keyword.put(:annotations, build_annotations(opts))
  end

  defp build_annotations(opts) do
    @default_annotations
    |> Map.put("flame.org/pool-config-ref", Keyword.get(opts, :pool_config_ref))
    |> Map.put("flame.org/otp-app", Keyword.get(opts, :otp_app))
    |> Map.put("flame.org/cookie-secret-ref", Keyword.get(opts, :cookie_secret_ref))
    |> Map.put(
      "flame.org/runner-termination-timeout",
      Keyword.get(opts, :runner_termination_timeout) |> Integer.to_string()
    )
  end

  defp render_manifest(opts) do
    annotations = Keyword.fetch!(opts, :annotations)
    name = Keyword.fetch!(opts, :name)
    namespace = Keyword.fetch!(opts, :namespace)
    app_label = Keyword.fetch!(opts, :app_label)
    container_name = Keyword.fetch!(opts, :container_name)
    image = Keyword.fetch!(opts, :image)
    replicas = Keyword.fetch!(opts, :replicas)
    resources = Keyword.get(opts, :resources, @default_resources)

    [
      "---",
      "apiVersion: apps/v1",
      "kind: Deployment",
      "metadata:",
      "  name: #{name}",
      "  namespace: #{namespace}",
      "spec:",
      "  replicas: #{replicas}",
      "  selector:",
      "    matchLabels:",
      "      app: #{app_label}",
      "  template:",
      "    metadata:",
      "      labels:",
      "        app: #{app_label}",
      "      annotations:"
    ] ++
      render_annotations(annotations) ++
      [
        "    spec:",
        "      containers:",
        "        - name: #{container_name}",
        "          image: #{image}",
        "          resources:",
        "#{render_resources(resources, 12)}"
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
  end

  defp render_annotations(annotations) do
    annotations
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> ["        #{key}: #{inspect(value)}"] end)
  end

  defp render_resources(resources, indent) do
    indent = String.duplicate(" ", indent)

    [
      "#{indent}limits:",
      "#{indent}  cpu: #{get_in(resources, ["limits", "cpu"])}",
      "#{indent}  memory: #{get_in(resources, ["limits", "memory"])}",
      "#{indent}requests:",
      "#{indent}  cpu: #{get_in(resources, ["requests", "cpu"])}",
      "#{indent}  memory: #{get_in(resources, ["requests", "memory"])}"
    ]
    |> Enum.join("\n")
  end
end

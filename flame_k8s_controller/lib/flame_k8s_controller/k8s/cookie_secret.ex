defmodule FlameK8sController.K8s.CookieSecret do
  @moduledoc """
  Replicates the operator Erlang cookie Secret into workload namespaces.
  """

  alias FlameK8sController.K8sConn

  require Logger

  @default_secret_name "flame-erlang-cookie"
  @field_manager "flame-k8s-controller"
  @k8s_env Mix.env()

  @spec ensure_namespace_secret(binary(), binary(), keyword()) :: :ok | {:error, binary()}
  def ensure_namespace_secret(target_namespace, target_secret_name \\ @default_secret_name, opts \\ []) do
    cond do
      not replication_enabled?() ->
        :ok

      blank?(target_namespace) ->
        {:error, "Missing target namespace for Erlang cookie secret replication"}

      blank?(target_secret_name) ->
        {:error, "Missing target secret name for Erlang cookie secret replication"}

      true ->
        conn = Keyword.get(opts, :conn) || K8sConn.get!(@k8s_env)
        source_namespace = source_namespace()
        source_secret_name = source_secret_name()

        with {:ok, source_secret} <- fetch_secret(conn, source_namespace, source_secret_name),
             :ok <- apply_secret(conn, build_replica_secret(source_secret, target_namespace, target_secret_name)) do
          :ok
        else
          {:error, reason} = error ->
            Logger.error(
              "Failed to replicate Erlang cookie secret #{source_namespace}/#{source_secret_name} to #{target_namespace}/#{target_secret_name}: #{reason}"
            )

            error
        end
    end
  end

  defp replication_enabled? do
    Application.get_env(:flame_k8s_controller, :cookie_secret_replication_enabled, true)
  end

  defp source_namespace do
    System.get_env("BONNY_POD_NAMESPACE") || "flame"
  end

  defp source_secret_name do
    System.get_env("FLAME_COOKIE_SECRET_NAME") || @default_secret_name
  end

  defp fetch_secret(conn, namespace, name) do
    case K8s.Client.get("v1", "Secret", namespace: namespace, name: name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, secret} ->
        {:ok, secret}

      {:error, reason} ->
        {:error, format_fetch_error(namespace, name, reason)}
    end
  end

  defp apply_secret(conn, secret) do
    case K8s.Client.apply(secret, field_manager: @field_manager, force: true)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _secret} -> :ok
      {:error, reason} -> {:error, "Kubernetes apply failed: #{inspect(reason)}"}
    end
  end

  defp build_replica_secret(source_secret, target_namespace, target_secret_name) do
    source_metadata = Map.get(source_secret, "metadata", %{})

    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{
        "name" => target_secret_name,
        "namespace" => target_namespace,
        "labels" => replica_labels(Map.get(source_metadata, "labels", %{}), source_metadata),
        "annotations" => replica_annotations(
          Map.get(source_metadata, "annotations", %{}),
          source_metadata,
          target_namespace,
          target_secret_name
        )
      },
      "type" => Map.get(source_secret, "type", "Opaque"),
      "immutable" => Map.get(source_secret, "immutable"),
      "data" => Map.get(source_secret, "data", %{})
    }
    |> compact_nil_values()
  end

  defp replica_labels(labels, source_metadata) do
    labels
    |> Map.merge(%{
      "app.kubernetes.io/managed-by" => @field_manager,
      "flame.org/replicated-cookie-secret" => "true",
      "flame.org/source-secret-name" => Map.get(source_metadata, "name", source_secret_name())
    })
  end

  defp replica_annotations(annotations, source_metadata, target_namespace, target_secret_name) do
    annotations
    |> Map.drop([
      "kubectl.kubernetes.io/last-applied-configuration",
      "deployment.kubernetes.io/revision"
    ])
    |> Map.merge(%{
      "flame.org/source-secret-namespace" => Map.get(source_metadata, "namespace", source_namespace()),
      "flame.org/source-secret-name" => Map.get(source_metadata, "name", source_secret_name()),
      "flame.org/replicated-to-namespace" => target_namespace,
      "flame.org/replicated-secret-name" => target_secret_name
    })
  end

  defp compact_nil_values(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp format_fetch_error(namespace, name, reason) do
    if not_found_error?(reason) do
      "Source Erlang cookie secret '#{name}' was not found in namespace '#{namespace}'"
    else
      "Failed to read source Erlang cookie secret '#{name}' from namespace '#{namespace}': #{inspect(reason)}"
    end
  end

  defp not_found_error?(%K8s.Client.APIError{reason: "NotFound"}), do: true
  defp not_found_error?(%{reason: "NotFound"}), do: true
  defp not_found_error?(%{status: 404}), do: true
  defp not_found_error?(_), do: false

  defp blank?(value), do: is_nil(value) or value == ""
end

defmodule FlameK8sController.RunnerGcScheduler do
  @moduledoc """
  Periodic cleanup for stale completed FlameRunner resources.

  This scheduler runs only on the operator instance that currently holds the
  leader lease. That keeps cleanup centralized and avoids duplicate GC work
  across replicas.
  """

  use GenServer

  require Logger

  @default_interval_ms 30_000
  @default_pending_ttl_seconds 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    conn = Keyword.get(opts, :conn)
    interval_ms = interval_ms_from_env(Keyword.get(opts, :interval_ms, @default_interval_ms))

    Process.send_after(self(), :run_gc, interval_ms)

    {:ok, %{conn: conn, interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:run_gc, %{conn: conn, interval_ms: interval_ms} = state) do
    if is_leader?(conn) do
      Logger.info("FlameRunner GC scheduler tick on leader instance")
      cleanup_completed_runners(conn)
    else
      Logger.debug("FlameRunner GC scheduler skipping because this operator instance is not leader")
    end

    Process.send_after(self(), :run_gc, interval_ms)
    {:noreply, state}
  end

  defp interval_ms_from_env(configured_interval_ms) do
    case System.get_env("FLAME_RUNNER_GC_INTERVAL_MS") do
      nil -> configured_interval_ms
      "" -> configured_interval_ms
      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> configured_interval_ms
        end
    end
  end

  defp cleanup_completed_runners(conn) do
    retention_limit = FlameK8sController.Handler.FlameRunnerHandler.runner_retention_limit()
    pending_ttl_seconds = pending_ttl_seconds_from_env(@default_pending_ttl_seconds)

    if retention_limit <= 0 and pending_ttl_seconds <= 0 do
      Logger.info(
        "FlameRunner GC scheduler skipped: retention limit is #{retention_limit} and pending TTL is #{pending_ttl_seconds}s"
      )

      :ok
    else
      case K8s.Client.list("flame.org/v1", "FlameRunner")
           |> K8s.Client.put_conn(conn)
           |> K8s.Client.run() do
        {:ok, %{"items" => items}} ->
          terminal_runners =
            Enum.filter(items, fn runner ->
              phase = get_in(runner, ["status", "phase"])
              phase in ["Succeeded", "Failed"] and not deleting_resource?(runner)
            end)

          {groups, skipped_without_parent} =
            Enum.reduce(terminal_runners, {%{}, 0}, fn runner, {acc, skipped} ->
              namespace = get_in(runner, ["metadata", "namespace"]) || "default"
              parent =
                get_in(runner, ["spec", "parentRef", "name"]) ||
                  get_in(runner, ["spec", :parentRef, :name])

              if is_binary(parent) and parent != "" do
                key = {namespace, logical_parent_key(parent)}
                {Map.update(acc, key, [runner], &[runner | &1]), skipped}
              else
                {acc, skipped + 1}
              end
            end)

          retention_deleted_count =
            if retention_limit > 0 do
              groups
              |> Enum.reduce(0, fn {{namespace, _parent}, runners}, acc_deleted ->
                stale =
                  runners
                  |> Enum.sort_by(fn runner ->
                    get_in(runner, ["metadata", "creationTimestamp"]) || "0000-01-01T00:00:00Z"
                  end, :desc)
                  |> Enum.drop(retention_limit)

                Enum.each(stale, fn runner ->
                  runner_name = get_in(runner, ["metadata", "name"])

                  delete_flame_runner(conn, namespace, runner_name,
                    "Deleted stale completed FlameRunner #{namespace}/#{runner_name} due to retention policy"
                  )
                end)

                acc_deleted + length(stale)
              end)
            else
              0
            end

          pending_ttl_candidates =
            if pending_ttl_seconds > 0 do
              Enum.filter(items, fn runner ->
                not deleting_resource?(runner) and stale_pending_runner?(runner, pending_ttl_seconds)
              end)
            else
              []
            end

          Enum.each(pending_ttl_candidates, fn runner ->
            namespace = get_in(runner, ["metadata", "namespace"]) || "default"
            runner_name = get_in(runner, ["metadata", "name"])
            phase = get_in(runner, ["status", "phase"]) || "Unknown"

            delete_flame_runner(conn, namespace, runner_name,
              "Deleted stale #{phase} FlameRunner #{namespace}/#{runner_name} due to pending TTL #{pending_ttl_seconds}s"
            )
          end)

          Logger.info(
            "FlameRunner GC scheduler scan completed: total=#{length(items)} terminal=#{length(terminal_runners)} groups=#{map_size(groups)} skipped_without_parent=#{skipped_without_parent} retention_limit=#{retention_limit} retention_deleted=#{retention_deleted_count} pending_ttl_seconds=#{pending_ttl_seconds} pending_deleted=#{length(pending_ttl_candidates)}"
          )

        {:error, reason} ->
          Logger.warning("FlameRunner GC scheduler failed to list FlameRunner resources: #{inspect(reason)}")
      end
    end
  end

  @doc false
  def stale_pending_runner?(runner, ttl_seconds) when is_map(runner) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    phase = get_in(runner, ["status", "phase"])

    if phase in ["Pending", "NotProvisioned"] do
      case get_in(runner, ["metadata", "creationTimestamp"]) do
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, created_at, _offset} -> DateTime.diff(DateTime.utc_now(), created_at, :second) >= ttl_seconds
            _ -> false
          end

        _ ->
          false
      end
    else
      false
    end
  end

  def stale_pending_runner?(_runner, _ttl_seconds), do: false

  defp pending_ttl_seconds_from_env(configured_pending_ttl_seconds) do
    case System.get_env("FLAME_RUNNER_PENDING_TTL_SECONDS") do
      nil -> configured_pending_ttl_seconds
      "" -> configured_pending_ttl_seconds

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> configured_pending_ttl_seconds
        end
    end
  end

  defp delete_flame_runner(conn, namespace, runner_name, success_log_message) do
    case K8s.Client.delete("flame.org/v1", "FlameRunner", namespace: namespace, name: runner_name)
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, _} ->
        Logger.info(success_log_message)

      {:error, reason} ->
        if resource_not_found?(reason) do
          :ok
        else
          Logger.warning("Failed to delete FlameRunner #{namespace}/#{runner_name}: #{inspect(reason)}")
        end
    end
  end

  defp resource_not_found?(%K8s.Client.APIError{reason: "NotFound"}), do: true
  defp resource_not_found?(%{reason: "NotFound"}), do: true
  defp resource_not_found?(%{status: 404}), do: true
  defp resource_not_found?(_), do: false

  defp deleting_resource?(resource) do
    resource
    |> Map.get("metadata", %{})
    |> Map.has_key?("deletionTimestamp")
  end

  defp logical_parent_key(parent_name) when is_binary(parent_name) do
    # Normalize pod-instance names to a stable workload key.
    # Example: flame-parent-example-58d8fd4456-9lmz5 -> flame-parent-example-58d8fd4456
    case Regex.run(~r/^(.+)-[a-z0-9]{5}$/, parent_name) do
      [_, base] -> base
      _ -> parent_name
    end
  end

  defp is_leader?(conn) do
    lease_name = leader_lease_name()

    case K8s.Client.get("coordination.k8s.io/v1", "Lease",
           namespace: Bonny.Config.namespace(),
           name: lease_name
         )
         |> K8s.Client.put_conn(conn)
         |> K8s.Client.run() do
      {:ok, %{"spec" => %{"holderIdentity" => holder_identity}}} ->
        holder_identity == Bonny.Config.instance_name()

      _ ->
        false
    end
  end

  defp leader_lease_name do
    operator_hash =
      :crypto.hash(:sha, Atom.to_string(FlameK8sController.Operator))
      |> String.slice(0..15)
      |> Base.encode16(case: :lower)

    "#{Bonny.Config.namespace()}-#{Bonny.Config.name()}-#{operator_hash}"
  end
end

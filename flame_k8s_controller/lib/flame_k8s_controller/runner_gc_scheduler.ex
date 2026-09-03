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

    if retention_limit <= 0 do
      Logger.info("FlameRunner GC scheduler skipped: retention limit is #{retention_limit}")
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

        deleted_count =
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

              case K8s.Client.delete("flame.org/v1", "FlameRunner", namespace: namespace, name: runner_name)
                   |> K8s.Client.put_conn(conn)
                   |> K8s.Client.run() do
                {:ok, _} ->
                  Logger.info("Deleted stale completed FlameRunner #{namespace}/#{runner_name} due to retention policy")

                {:error, reason} ->
                  Logger.warning("Failed to delete stale completed FlameRunner #{namespace}/#{runner_name}: #{inspect(reason)}")
              end
            end)

            acc_deleted + length(stale)
          end)

        Logger.info(
          "FlameRunner GC scheduler scan completed: total=#{length(items)} terminal=#{length(terminal_runners)} groups=#{map_size(groups)} skipped_without_parent=#{skipped_without_parent} retention_limit=#{retention_limit} deleted=#{deleted_count}"
        )

      {:error, reason} ->
        Logger.warning("FlameRunner GC scheduler failed to list FlameRunner resources: #{inspect(reason)}")
    end
    end
  end

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

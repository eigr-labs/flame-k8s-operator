defmodule FlameK8sController.Application do
  @moduledoc false
  use Application

  require Logger

  @port 9001

  def start(_type, args) do
    env = Keyword.get(args, :env, runtime_env())

    if bootstrap_tls_only?() do
      secret_name = System.get_env("FLAME_BOOTSTRAP_TLS_SECRET", "flame-webhook-tls")
      FlameK8sController.Webhooks.bootstrap_tls(:prod, secret_name)
      System.halt(0)
    end

    opts = [strategy: :one_for_one, name: FlameK8sController.Supervisor]
    Supervisor.start_link(children(env), opts)
  end

  defp children(:test), do: []

  defp children(env) do
    conn = FlameK8sController.K8sConn.get!(env)

    [
      {FlameK8sController.Operator,
       conn: conn, enable_leader_election: true},
      {FlameK8sController.RunnerGcScheduler, conn: conn},
      {Bandit,
       plug: FlameK8sController.Router,
       port: @port,
       certfile: "/mnt/cert/tls.crt",
       keyfile: "/mnt/cert/tls.key",
       scheme: :https}
    ]
  end

  defp runtime_env do
    System.get_env("MIX_ENV", "prod")
    |> String.to_atom()
  end

  defp bootstrap_tls_only? do
    System.get_env("FLAME_BOOTSTRAP_TLS_ONLY", "false") == "true"
  end
end

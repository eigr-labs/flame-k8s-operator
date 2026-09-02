defmodule FlameK8sController.Webhooks do
  @moduledoc false

  alias FlameK8sController.K8sConn

  require Logger

  @spec bootstrap_tls(atom(), binary()) :: :ok
  def bootstrap_tls(env, secret_name) do
    Application.ensure_all_started(:k8s)
    conn = K8sConn.get!(env)
    service_namespace = System.get_env("BONNY_POD_NAMESPACE", "flame")
    service_name = System.get_env("BONNY_OPERATOR_NAME", "flame-controller")

    with {:certs, {:ok, ca_bundle}} <-
           {:certs,
            K8sWebhoox.ensure_certificates(
              conn,
              service_namespace,
              service_name,
              service_namespace,
              secret_name
            )},
         {:webhook_config, :ok} <-
           {:webhook_config,
            K8sWebhoox.update_admission_webhook_configs(conn, "flame-k8s", ca_bundle)} do
      Logger.info("TLS Bootstrap completed.")
    else
      error ->
        Logger.error("TLS Bootstrap failed: #{inspect(error)}")
        exit({:shutdown, 1})
    end
  end
end

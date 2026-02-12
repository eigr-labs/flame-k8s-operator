defmodule FlameK8sController.Routes.Api do
  @moduledoc """
  API routes for the Flame K8s Controller.

  Note: Most functionality is now handled via CRDs and the Bonny operator.
  These routes are kept for potential future extensions or monitoring.
  """
  use FlameK8sController.Routes.Base

  get "/" do
    send!(
      conn,
      200,
      %{
        status: "ok",
        message: "Flame K8s Controller API",
        version: "v1"
      },
      "application/json"
    )
  end

  match _ do
    send_resp(conn, 404, "Not found!")
  end
end

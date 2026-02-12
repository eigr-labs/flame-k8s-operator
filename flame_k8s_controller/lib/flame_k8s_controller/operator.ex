defmodule FlameK8sController.Operator do
  @moduledoc """
  Defines the operator.

  The operator resource defines custom resources, watch queries and their
  controllers and serves as the entry point to the watching and handling
  processes.
  """

  use Bonny.Operator, default_watch_namespace: "default"

  step(Bonny.Pluggable.Logger, level: :info)
  step(:delegate_to_controller)
  step(Bonny.Pluggable.ApplyStatus)
  step(Bonny.Pluggable.ApplyDescendants)

  @impl Bonny.Operator
  def controllers(watching_namespace, _opts) do
    [
      %{
        query: K8s.Client.watch("flame.org/v1", "FlameRunner", namespace: watching_namespace),
        controller: FlameK8sController.Controller.FlameRunner
      },
      %{
        query: K8s.Client.watch("flame.org/v1", "FlamePool", namespace: watching_namespace),
        controller: FlameK8sController.Controller.FlamePool
      }
    ]
  end

  @impl Bonny.Operator
  def crds() do
    [
      Bonny.API.CRD.new!(
        names:
          Bonny.API.CRD.kind_to_names("FlameRunner", [
            "fr",
            "flamerunner",
            "flamerunners",
            "runner",
            "runners"
          ]),
        group: "flame.org",
        scope: :Namespaced,
        versions: [FlameK8sController.Versions.Api.V1.FlameRunner]
      ),
      Bonny.API.CRD.new!(
        names:
          Bonny.API.CRD.kind_to_names("FlamePool", [
            "flamepool",
            "flamepools",
            "pool",
            "pools"
          ]),
        group: "flame.org",
        scope: :Namespaced,
        versions: [FlameK8sController.Versions.Api.V1.FlamePool]
      )
    ]
  end

  def get_args(resource) do
    annotations = K8s.Resource.annotations(resource)
    labels = K8s.Resource.labels(resource)
    metadata = K8s.Resource.metadata(resource)
    name = K8s.Resource.name(resource)
    ns = K8s.Resource.namespace(resource) || "default"
    spec = Map.get(resource, "spec")

    %{
      annotations: annotations,
      labels: labels,
      name: name,
      namespace: ns,
      metadata: metadata,
      params: spec
    }
  end
end

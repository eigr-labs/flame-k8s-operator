defmodule FlameK8sController.Controller.FlamePool do
  use Bonny.ControllerV2
  require Bonny.API.CRD

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(FlameK8sController.Handler.FlamePoolHandler)
  step(Bonny.Pluggable.Finalizer,
    id: FlameK8sController.Handler.FlamePoolHandler.finalizer_id(),
    impl: &FlameK8sController.Handler.FlamePoolHandler.cleanup/1,
    add_to_resource: true,
    log_level: :info
  )

  @impl true
  def rbac_rules() do
    [
      to_rbac_rule({"", "secrets", "*"}),
      to_rbac_rule({"", ["services", "configmaps"], "*"}),
      to_rbac_rule({"", ["nodes"], ["get", "list"]}),
      to_rbac_rule({"scheduling.k8s.io", ["priorityclasses"], ["get", "list", "create"]}),
      to_rbac_rule({"flame.org", ["flamerunners"], ["get", "list"]})
    ]
  end
end

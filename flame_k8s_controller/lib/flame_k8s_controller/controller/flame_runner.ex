defmodule FlameK8sController.Controller.FlameRunner do
  use Bonny.ControllerV2
  require Bonny.API.CRD

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(FlameK8sController.Handler.FlameRunnerHandler)

  @impl true
  def rbac_rules() do
    [
      to_rbac_rule({"rbac.authorization.k8s.io", ["role", "roles", "rolebindings"], "*"}),
      to_rbac_rule({"", ["serviceaccount", "serviceaccounts"], "*"}),
      to_rbac_rule({"", "pods", "*"}),
      to_rbac_rule({"", ["node", "nodes"], ["get", "list"]}),
      to_rbac_rule({"apps", "deployments", "*"}),
      to_rbac_rule({"", ["services", "configmaps"], "*"})
    ]
  end
end

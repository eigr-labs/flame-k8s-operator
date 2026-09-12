# FlameK8s

Kubernetes backend integration for [FLAME](https://github.com/phoenixframework/flame).

This library implements `FLAME.Backend` and delegates runner lifecycle to
Kubernetes through the `FlameRunner` and `FlamePool` custom resources managed
by the flame-k8s operator.

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:flame_k8s, "~> 0.1.0"}
  ]
end
```

## Configure Your Application

Enable the backend in your runtime configuration (usually in production):

```elixir
if config_env() == :prod do
  config :flame, :backend, FLAME.K8sBackend
  config :flame, FLAME.K8sBackend,
    log: :debug,
    boot_timeout: 30_000
end
```

## How It Works

1. Your app invokes FLAME work (`FLAME.call/3`, `FLAME.cast/3`).
2. `FLAME.K8sBackend` creates a `FlameRunner` custom resource.
3. The operator reconciles `FlameRunner` and creates the runner pod.
4. The runner pod connects back via distributed Erlang.
5. Work executes remotely and runner resources are cleaned up.

## Install The Operator

This backend requires the operator and CRDs installed in the target cluster.

Use the release assets published with each GitHub release. No repository clone is required.

Latest release:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/latest/download/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --namespace flame
```

Pinned release tag:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.2/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --tag v0.1.2 --namespace flame
```

This installer downloads the release bundle, creates or reuses the Erlang cookie secret,
waits for CRDs to be established, applies the operator manifests in the target namespace,
and merges the default FLAME Argo CD health customizations into `argocd-cm` when Argo CD is present.

If you need to apply individual YAML manifests directly, use the release asset files instead of cloning the repository.

## Generate A FLAME-Ready Deployment

The library includes a mix task that generates a Deployment with the FLAME
annotations already filled in.

```bash
mix flame.gen.deployment \
  --name flame-parent-example \
  --namespace default \
  --image ghcr.io/eigr-labs/flame-parent-example:latest
```

Optional flags include `--pool-config-ref`, `--otp-app`, `--cookie-secret-ref`,
and `--runner-termination-timeout`.

## Argo CD Notes

- `FlamePool` is the recommended resource to evaluate with custom Argo CD health checks because it is stable and declarative.
- Generated `FlameRunner` resources are ephemeral. By default, the workload admission flow marks them with `argocd.argoproj.io/ignore-healthcheck: "true"` so normal runner churn does not degrade the Argo CD application.
- The operator installation bundle ships a separate Argo CD customization manifest outside the operator Kustomize directory, and the installer applies it automatically when `argocd-cm` is present. Treat that default as the baseline and override it only if you need different health semantics.
- To opt out of that default, add `flame.org/argocd-ignore-runner-healthcheck: "false"` to the workload pod template annotations.
- If you opt out, define a custom Argo CD health check for `FlameRunner` in `argocd-cm` based on `status.phase`, `status.reason`, `status.message`, and `status.observedGeneration`.

## Apply Example CR Instances

After installing the operator, apply example resources:

```bash
kubectl apply -f examples/crds/flamepool-apply.yaml
kubectl apply -f examples/flame_example/.k8s/deployment.yaml
```

The direct `FlameRunner` manifest is still available for manual CR testing, but
the normal application flow is driven by the annotated Deployment and the
mutating webhook.

Inspect status:

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
```

## Environment Notes

- In cluster, backend auth uses service account credentials.
- Outside cluster, backend reads kubeconfig from `KUBECONFIG` (first path when
  multiple are provided), with fallback to `~/.kube/config`.
- Backend includes `FLAME_NODE_BASE` in generated `FlameRunner` env so runner
  pods can derive `RELEASE_NODE` as `$(FLAME_NODE_BASE)@$(POD_IP)`.


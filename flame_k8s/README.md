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

Option 1: use project release manifest.

```bash
kubectl apply -f <release-manifest-url>
```

Option 2: generate manifests from this repository and apply with kustomize.

```bash
make generate-k8s-manifests
kubectl apply -k .k8s/install/manifests
```

## Apply Example CR Instances

After installing the operator, apply example resources:

```bash
kubectl apply -f examples/crds/flamepool-apply.yaml
kubectl apply -f examples/crds/flamerunner-apply.yaml
```

Inspect status:

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
```

## Environment Notes

- In cluster, backend auth uses service account credentials.
- Outside cluster, backend reads kubeconfig from `KUBECONFIG` (first path when
  multiple are provided), with fallback to `~/.kube/config`.


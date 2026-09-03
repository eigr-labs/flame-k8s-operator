# Quickstart

This quickstart gets you from zero to first remote FLAME execution.

## 1. Add dependency

In your `mix.exs`:

```elixir
def deps do
  [
    {:flame_k8s, "~> 0.1.0"}
  ]
end
```

Then fetch deps:

```bash
mix deps.get
```

## 2. Configure FLAME backend

In runtime config (usually production):

```elixir
if config_env() == :prod do
  config :flame, :backend, FLAME.K8sBackend

  config :flame, FLAME.K8sBackend,
    log: :info,
    boot_timeout: 30_000
end
```

## 3. Install operator + CRDs

Apply operator manifests and CRDs to your cluster.

Install from GitHub Release assets. Repository clone is not required.

Latest release:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/latest/download/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --namespace flame
```

Pinned release tag:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --tag v0.1.0 --namespace flame
```

The installer downloads `flame-k8s-manifests-<tag>.tar.gz`, creates or reuses
the cookie secret, applies CRDs, waits for CRD establishment, then applies the
operator manifests.

See the operator installation guide for direct remote YAML apply options,
verification, and troubleshooting.

## 4. Deploy your parent app

Generate a FLAME-ready deployment:

```bash
mix flame.gen.deployment \
  --name my-flame-parent \
  --namespace default \
  --image ghcr.io/your-org/your-image:latest
```

Apply it:

```bash
kubectl apply -f .k8s/deployment.yaml
```

## 5. Verify everything is working

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
kubectl get pods -A
```

If `FlameRunner` resources appear and complete, the backend is working.

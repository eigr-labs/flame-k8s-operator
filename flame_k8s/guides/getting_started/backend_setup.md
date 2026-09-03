# Backend Setup

This guide shows how to enable `FLAME.K8sBackend` in an Elixir application.

## 1. Add Dependency

In your `mix.exs`:

```elixir
def deps do
  [
    {:flame_k8s, "~> 0.1.0"}
  ]
end
```

## 2. Configure FLAME Backend

In runtime configuration (usually production):

```elixir
if config_env() == :prod do
  config :flame, :backend, FLAME.K8sBackend

  config :flame, FLAME.K8sBackend,
    log: :debug,
    boot_timeout: 30_000
end
```

## 3. Install Operator and CRDs

Install the operator and CRDs before running workloads.

The recommended path is remote installation from GitHub Release assets.
Follow the full steps in the Operator Installation guide.

## 4. Run FLAME Work

Once configured, existing calls such as `FLAME.call/3` and `FLAME.cast/3` are
executed through Kubernetes runners managed by the operator.

## 5. Validate Integration

Use these checks after deploy:

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
kubectl get pods -A
```

If you see `FlameRunner` resources being created and moving through lifecycle
phases, your backend and operator integration is healthy.

## Continue Reading

- Operator Installation
- Operator How It Works
- Operator Features
- Operator Operations

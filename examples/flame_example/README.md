# Flame Example

This example shows how to run a FLAME-enabled application using the `flame_k8s`
backend and the `flame_k8s_controller` operator in Kubernetes.

## What This Example Covers

- How the application enables `FLAME.K8sBackend`
- How Kubernetes annotations trigger runner orchestration
- How to install the operator in a cluster
- How to apply Flame CRDs and CR instances
- How the example application actually calls `FLAME.call/3` on startup

## How The Library Is Used In The Example App

The example app depends on the local `flame_k8s` library in
`examples/flame_example/mix.exs`:

```elixir
{:flame_k8s, path: "../../flame_k8s"}
```

In production config (`examples/flame_example/config/config.exs`), the backend is
set to Kubernetes:

```elixir
config :flame, :backend, FLAME.K8sBackend
config :flame, FLAME.K8sBackend, log: :debug
```

In the parent Deployment (`examples/flame_example/.k8s/deployment.yaml`), the
pod template annotations enable FLAME behavior:

- `flame.org/enabled: "true"`
- `flame.org/dist-auto-config: "true"`
- `flame.org/otp-app: "flame_example"`
- `flame.org/pool-config-ref: "custom-pool-example"`

These annotations are consumed by the operator webhook/controller so FLAME
runners are created with the selected pool profile.

The example application also starts a small `FLAME.Pool` and a demo worker that
calls `FLAME.call/3` on boot. That makes the local example exercise the full
parent -> backend -> operator -> runner path instead of just compiling the
integration code.

## Prerequisites

- Kubernetes cluster with `kubectl` access
- Docker (if building operator image locally)
- Elixir/OTP compatible with this repository

## Install The Operator In Kubernetes

There are two common paths.

### Option 1: From release manifest

Use the published install manifest from the project releases and apply it to the
cluster.

```bash
kubectl apply -f <release-manifest-url>
```

### Option 2: Generate manifests locally (repository workflow)

From repository root:

```bash
make generate-k8s-manifests
kubectl apply -k .k8s/install/manifests
```

This installs:

- Operator deployment and RBAC
- MutatingWebhookConfiguration and service
- CRD definitions (`FlamePool`, `FlameRunner`)

## Apply Flame CRDs (Custom Resources)

After the operator is installed, apply the example pool and annotated Deployment
from this folder. The operator now creates the workload service account and RBAC
automatically when the Deployment is admitted:

```bash
kubectl apply -f examples/flame_example/.k8s/pool.yaml
kubectl apply -f examples/flame_example/.k8s/deployment.yaml
```

The pool example includes an optional high-level scheduling block:

```yaml
spec:
	scheduling:
		provider: karpenter
		class: gpu
		lifecycle: spot
		architecture: amd64
		priority: high
```

The operator translates this into Pod scheduling defaults (selectors,
tolerations, priority class). For fine-grained control, continue using
`spec.podTemplate.spec` directly.

Provider behavior:

- `provider: generic` uses non-provider-specific label conventions
- `provider: karpenter` keeps `karpenter.sh/capacity-type` mapping

To inspect how scheduling was resolved by the operator:

```bash
kubectl get flamepool custom-pool-example -n default -o yaml
```

Quick summary columns are also available:

```bash
kubectl get flamepool custom-pool-example -n default
```

Look at `InfraReady` and `MatchingNodes` (format `[node-a,node-b,node-c,...]`, capped at 3 names).

Look at status fields:

- `status.resolvedScheduling`
- `status.schedulingFeedback`
- `status.conditions[type=SchedulingResolved|SchedulingInfrastructure]`

That is the real flow. The `FlameRunner` CR should be created by the webhook/backend path after the application calls `FLAME.call/3`, not by applying a runner manifest directly.

To inspect:

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
```

## Run The Example Workload Manifests

You can also apply the app-specific manifests under this folder:

Or run the local helper in this directory:

```bash
make all
```

## Notes

- Do not set `status` manually in CR manifests.
- Finalizers are managed by the operator.
- Keep pool/deployment namespace values aligned with your target namespace.

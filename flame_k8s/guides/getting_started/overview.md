# FLAME + Kubernetes: Overview

This project gives FLAME a Kubernetes backend.

In simple terms:

- Your app calls `FLAME.call/3` or `FLAME.cast/3`.
- `FLAME.K8sBackend` asks Kubernetes for a runner.
- The operator creates and manages that runner pod.
- The runner connects back and executes the work.
- The operator cleans up resources when work finishes.

This documentation is organized to be practical and direct:

- Start with Quickstart.
- Then configure the backend in detail.
- Continue with operator installation and operation.
- Use Advanced docs for deployment automation.

## When to use this backend

Use `flame_k8s` when you want:

- FLAME workloads running in Kubernetes pods.
- Operator-managed lifecycle for runners.
- A webhook-based flow to inject FLAME runtime metadata into your Deployment.

## What you need first

- A Kubernetes cluster.
- The operator and CRDs installed.
- An Elixir app using FLAME.

Continue with the Quickstart guide.

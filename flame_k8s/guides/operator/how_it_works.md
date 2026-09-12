# Operator: How It Works

This section explains the runtime flow in simple steps.

## Main pieces

- `FLAME.K8sBackend` in your app.
- `FlameRunner` CR for each requested runner.
- `FlamePool` CR for runner pod templates and scheduling intent.
- Operator controllers and mutating webhook.

## End-to-end flow

1. Your app requests FLAME work.
2. Backend creates a `FlameRunner` resource.
3. Operator resolves pool/template and creates a runner pod.
4. Runner pod receives environment for distributed Erlang.
5. Runner connects back and executes work.
6. Operator updates runner status and handles cleanup.

## Webhook role

When workload annotations include `flame.org/enabled: "true"`, the mutating
webhook injects required runtime environment into the first container.

Optional annotations let you tune behavior:

- `flame.org/pool-config-ref`
- `flame.org/cookie-secret-ref`
- `flame.org/dist-auto-config`
- `flame.org/otp-app`
- `flame.org/argocd-ignore-runner-healthcheck`
- `flame.org/runner-termination-timeout`

## Why this design

- CRDs make runner lifecycle observable.
- Finalizers ensure controlled cleanup.
- Pool abstraction centralizes pod and scheduling defaults.
- Release manifests provide reproducible installation by version.

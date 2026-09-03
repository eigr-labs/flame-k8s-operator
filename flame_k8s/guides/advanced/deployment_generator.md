# Deployment Generator

The project includes `mix flame.gen.deployment` to generate a deployment manifest
with FLAME annotations preconfigured for the mutating webhook flow.

## Usage

```bash
mix flame.gen.deployment \
  --name flame-parent-example \
  --namespace default \
  --image ghcr.io/eigr-labs/flame-parent-example:latest
```

## Useful Options

- `--pool-config-ref`: References the `FlamePool` configuration.
- `--otp-app`: Explicit OTP application name for release metadata.
- `--cookie-secret-ref`: Secret containing the distributed Erlang cookie.
- `--runner-termination-timeout`: Runner termination grace period.

## Workflow

1. Generate deployment YAML with the mix task.
2. Apply it to the cluster.
3. Let the webhook inject FLAME metadata for runner orchestration.

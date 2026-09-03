# Operator Features

This guide summarizes the most important operator features.

## 1. Runner lifecycle reconciliation

- Creates runner pods from `FlameRunner` resources.
- Mirrors pod state into `FlameRunner.status`.
- Handles retries while provisioning.

## 2. Pool-based runner templates

- `FlamePool.spec.podTemplate` defines runner pod baseline.
- `FlamePool.spec.scheduling` allows high-level scheduling intent.
- Status reports scheduling translation and infra matching feedback.

## 3. Mutating admission for workloads

- Supports Deployment and StatefulSet pod templates.
- Injects FLAME runtime environment when enabled.
- Supports cookie secret override per workload.

## 4. Distribution auto-configuration

- Parent workloads can receive `RELEASE_DISTRIBUTION` and `RELEASE_NODE`.
- Runner pods derive node names from `FLAME_NODE_BASE` and pod IP.
- Auto-injection can be disabled with annotation when needed.

## 5. Secret handling for Erlang cookie

- Installer creates or reuses operator namespace cookie secret.
- Operator ensures secret availability in target workload namespace.

## 6. Deterministic cleanup with finalizers

- Runner cleanup finalizer removes descendant resources.
- Pool protection finalizer blocks deletion while active runners exist.

## 7. Versioned installation assets

GitHub Releases publish:

- `flame-k8s-manifests-vX.Y.Z.tar.gz`
- Individual YAML manifests
- `install-operator.sh`

This enables reproducible installation and upgrades.

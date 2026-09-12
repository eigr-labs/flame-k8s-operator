# FlameK8sController

FlameK8sController is the Kubernetes operator component that reconciles
FlameRunner and FlamePool custom resources used by FLAME workloads.

## Supported CRDs

## Bonny Flow (Recommended)

This project follows Bonny reconciliation patterns:

- Input manifests (`kubectl apply`) should include only `metadata` and `spec`.
- `status` is controller-managed via `Bonny.Pluggable.ApplyStatus`.
- `metadata.finalizers` are controller-managed via `Bonny.Pluggable.Finalizer`.
- Erlang distribution cookies must be provided once in the operator namespace via a Kubernetes Secret.
- The operator watches all namespaces by default.

Do not set `status` or `finalizers` manually in your apply manifests.

### Install-Time Cookie Secret

The operator manifests do not ship with a static Erlang cookie Secret.

- Create or reuse `flame-erlang-cookie` in the operator namespace during installation.
- The operator replicates that Secret into FLAME workload namespaces on demand.

Helper scripts are provided at repository root:

- [scripts/install-operator.sh](../scripts/install-operator.sh)
- [scripts/ensure-flame-cookie-secret.sh](../scripts/ensure-flame-cookie-secret.sh)

Example:

```bash
bash scripts/install-operator.sh --manifest-dir .k8s/install/manifests --namespace flame
```

Release/tag based install:

```bash
curl -fsSL https://raw.githubusercontent.com/eigr-labs/flame-k8s-operator/v0.1.4/scripts/install-operator.sh | bash -s -- --tag v0.1.4 --namespace flame
```

### Apply Manifests (User Input)

- [examples/crds/flamepool-apply.yaml](../examples/crds/flamepool-apply.yaml)
- [examples/crds/flamerunner-apply.yaml](../examples/crds/flamerunner-apply.yaml)

### Real Cluster Flow

1. Apply pool: `kubectl apply -f examples/flame_example/.k8s/pool.yaml`
2. Apply annotated Deployment: `kubectl apply -f examples/flame_example/.k8s/deployment.yaml`
3. Observe the generated runner: `kubectl get flamerunners -n default -l flame.org/parent=flame-parent-example -o yaml`
4. Delete the Deployment and watch finalizer lifecycle on the generated runner:
: `kubectl delete deployment flame-parent-example -n default`
: `kubectl get flamerunner -n default -o yaml`

The runner manifest in [examples/crds/flamerunner-apply.yaml](../examples/crds/flamerunner-apply.yaml) is still useful for direct CR testing, but it is not part of the real application flow.

Bonny finalizer flow in this project:

- FlameRunner finalizer: `flame.org/flamerunner-cleanup`
- FlamePool finalizer: `flame.org/flamepool-protection`

### FlameRunner

Spec highlights:

- `parentRef.name` and `parentRef.namespace` are required.
- `image` is required.
- `poolRef` defaults to `default-pool`.
- `terminationGracePeriodSeconds` defaults to `60`.

Status highlights:

- `phase`: `NotProvisioned | Pending | Running | Succeeded | Failed | Terminating`
- `reason`, `message`, `lastUpdateTime`
- `podName`, `podIP`, `startTime`, `completionTime`
- `retryCount` for reconcile retries while the pod is still being provisioned
- `poolRef`, `poolNamespace`, `fallbackPoolUsed`
- `conditions`

Lifecycle behavior:

- On create/modify, the controller resolves `poolRef` and creates a pod descendant.
- If pool resolution fails, it uses a minimal fallback template and sets `fallbackPoolUsed`.
- Before a runner pod exists, the controller keeps `phase` at `NotProvisioned`.
- On reconcile, pod status is mirrored into FlameRunner status.
- If the pod is not found yet, retries are counted but the runner remains `NotProvisioned`.
- Only terminal reconcile errors transition the runner to `Failed`.
- During deletion, phase is set to `Terminating` and finalizer cleanup removes the runner pod.

### FlamePool

Spec highlights:

- `spec.podTemplate.spec.containers` must be a non-empty list.
- Each container entry must be an object.
- If container `env` is present, each env entry must be an object with non-empty `name`.
- Optional `spec.scheduling` can express high-level scheduling intent:
  - `provider`: `generic | karpenter`
  - `class`: `general | cpu | memory | gpu`
  - `lifecycle`: `any | on-demand | spot`
  - `architecture`: `any | amd64 | arm64`
  - `priority`: `low | normal | high | critical`

Status highlights:

- `phase`: `Ready | Invalid`
- `reason`, `message`, `lastUpdateTime`
- `conditions` include `Ready` and `TemplateValid`
- `resolvedScheduling` shows how `spec.scheduling` was translated
- `schedulingFeedback` reports infrastructure matching feedback
- `kubectl get flamepools` includes `InfraReady` and `MatchingNodes` columns

Scheduling feedback conditions:

- `SchedulingResolved`: translation from high-level intent to PodSpec defaults
- `SchedulingInfrastructure`: whether current node labels match generated selectors

Current mapping conventions:

- `class` -> `nodeSelector["flame.org/runner-class"]` (cluster label convention)
- `lifecycle` -> by provider:
  - `generic`: `nodeSelector["flame.org/capacity-type"]`
  - `karpenter`: `nodeSelector["karpenter.sh/capacity-type"]`
- `architecture` -> `nodeSelector["kubernetes.io/arch"]` (Kubernetes standard)
- `priority` -> `priorityClassName` (`flame-low|flame-normal|flame-high|flame-critical`)

PriorityClass bootstrap behavior:

- When one of the built-in flame priorities is selected, the operator reconciles
  the corresponding `PriorityClass` with create-if-not-exists semantics.
- This removes the need to pre-create `flame-low`, `flame-normal`,
  `flame-high`, or `flame-critical` manually in the cluster.

If your cluster uses different labels/taints, use `spec.podTemplate.spec` for explicit scheduling control.

`status.schedulingFeedback` includes:

- `matchingNodes`: number of matching nodes

Deletion behavior:

- FlamePool has a protective finalizer.
- If active FlameRunner resources still reference the pool in the namespace,
  deletion is blocked until runners are removed.

## Finalizers

The operator uses finalizers for deterministic cleanup:

- `flame.org/flamerunner-cleanup`
- `flame.org/flamepool-protection`

## Mutating webhook behavior

The mutating admission handler supports:

- `apps/v1/deployments`
- `apps/v1/statefulsets`

When `flame.org/enabled: "true"` is present on pod template annotations, the
handler appends FLAME runtime env vars to the first container.

Optional annotation:

- `flame.org/cookie-secret-ref`: overrides the default secret name `flame-erlang-cookie`

Distribution behavior:

- Parent workload pods can be mutated with `RELEASE_DISTRIBUTION=name` and
  `RELEASE_NODE=<otp-app>@$(POD_IP)` when `flame.org/dist-auto-config: "true"`.
- FlameRunner pods are generated with `RELEASE_DISTRIBUTION=name` and
  `RELEASE_NODE=$(FLAME_NODE_BASE)@$(POD_IP)`.
- When `flame.org/dist-auto-config: "false"` is explicitly set, distribution
  auto-injection is disabled for both parent workload and generated runner pods.
- `FLAME_NODE_BASE` is injected by the backend in the generated `FlameRunner.spec.env`.

Runner GC scheduler env:

- `FLAME_RUNNER_GC_INTERVAL_MS` (default `30000`)
- `FLAME_RUNNER_RETENTION_LIMIT` (default `5`)
- `FLAME_RUNNER_PENDING_TTL_SECONDS` (default `3600`, set `0` to disable)

The operator will ensure that the referenced Secret exists in the workload namespace before admitting the workload or creating runner pods.

### Compatibility and validation

The operator and runtime image are currently validated on the following Kubernetes environments and architecture:

| Environment | Status | Supported architecture |
| ---         | ---    | ---                    |
| Kind        | Tested | amd64                  |
| EKS         | Tested | amd64                  |

This project is currently validated for `amd64`. Support for other architectures is planned and will be added in upcoming releases as validation expands.

## Testing

Run unit tests:

```bash
mix test
```

Integration test behavior:

- Integration test files are under `test/integration/`.
- If `KUBECONFIG` is not configured, integration checks run as no-op and do not
  fail the suite.

Run integration tests with cluster access:

```bash
KUBECONFIG=./test/integration/kubeconfig-test.yaml mix test --include integration
```


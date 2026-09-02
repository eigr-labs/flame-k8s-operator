# FlameK8sController

FlameK8sController is the Kubernetes operator component that reconciles
FlameRunner and FlamePool custom resources used by FLAME workloads.

## Supported CRDs

## Bonny Flow (Recommended)

This project follows Bonny reconciliation patterns:

- Input manifests (`kubectl apply`) should include only `metadata` and `spec`.
- `status` is controller-managed via `Bonny.Pluggable.ApplyStatus`.
- `metadata.finalizers` are controller-managed via `Bonny.Pluggable.Finalizer`.

Do not set `status` or `finalizers` manually in your apply manifests.

### Apply Manifests (User Input)

- [examples/crds/flamepool-apply.yaml](../examples/crds/flamepool-apply.yaml)
- [examples/crds/flamerunner-apply.yaml](../examples/crds/flamerunner-apply.yaml)

### Real Cluster Flow

1. Apply pool: `kubectl apply -f examples/crds/flamepool-apply.yaml`
2. Apply runner: `kubectl apply -f examples/crds/flamerunner-apply.yaml`
3. Observe status: `kubectl get runners -n flame -o yaml`
4. Delete runner and watch finalizer lifecycle:
: `kubectl delete runner runner-example-001 -n flame`
: `kubectl get runner runner-example-001 -n flame -o yaml`

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

- `phase`: `Pending | Running | Succeeded | Failed | Terminating`
- `reason`, `message`, `lastUpdateTime`
- `podName`, `podIP`, `startTime`, `completionTime`
- `retryCount` for reconcile retries when pod lookup fails
- `poolRef`, `poolNamespace`, `fallbackPoolUsed`
- `conditions`

Lifecycle behavior:

- On create/modify, the controller resolves `poolRef` and creates a pod descendant.
- If pool resolution fails, it uses a minimal fallback template and sets `fallbackPoolUsed`.
- On reconcile, pod status is mirrored into FlameRunner status.
- If pod cannot be found repeatedly, retries are counted and eventually phase becomes `Failed`.
- During deletion, phase is set to `Terminating` and finalizer cleanup removes the runner pod.

### FlamePool

Spec highlights:

- `spec.podTemplate.spec.containers` must be a non-empty list.
- Each container entry must be an object.
- If container `env` is present, each env entry must be an object with non-empty `name`.

Status highlights:

- `phase`: `Ready | Invalid`
- `reason`, `message`, `lastUpdateTime`
- `conditions` include `Ready` and `TemplateValid`

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


# Operator Operations

This guide is for day-2 usage: verify, observe, and troubleshoot.

## Verify resources

```bash
kubectl get flamepools -A
kubectl get flamerunners -A
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp
```

## Inspect runner status

```bash
kubectl get flamerunner -n <ns> <name> -o yaml
```

Focus on:

- `status.phase`
- `status.reason`
- `status.message`
- `status.conditions`

## Inspect pool scheduling feedback

```bash
kubectl get flamepool -n <ns> <name> -o yaml
```

Focus on:

- `status.resolvedScheduling`
- `status.schedulingFeedback`
- `status.conditions`

## Argo CD health

`FlamePool` is the best default target for Argo CD custom health checks because it is long-lived and declarative. Its `status.phase`, `status.conditions`, and `status.observedGeneration` provide enough information for a reliable health script.

`FlameRunner` is ephemeral. By default, generated runners receive `argocd.argoproj.io/ignore-healthcheck: "true"` so transient provisioning and cleanup do not degrade the Argo CD application during normal FLAME operation.

The operator installation bundle includes a default Argo CD health customization manifest at `.k8s/install/argocd/argocd-cm-flame-health.yaml`. It lives outside the operator Kustomize directory on purpose, so GitOps installs of the operator do not try to manage `argocd-cm` as part of the operator application. The installer tries to merge it into `argocd-cm` automatically when Argo CD is detected in the cluster.

If you want Argo CD to evaluate runner health explicitly, set the workload annotation below to `"false"`. The installer-provided `FlameRunner` health script becomes active for tracked runners, and you can still override it later in `argocd-cm` if your environment needs different semantics.

```yaml
flame.org/argocd-ignore-runner-healthcheck: "false"
```

If you are not using the installer script, merge the defaults manually with:

```bash
kubectl -n argocd apply --server-side --field-manager=flame-k8s-operator-install -f .k8s/install/argocd/argocd-cm-flame-health.yaml
```

## Common checks

1. CRDs established:

```bash
kubectl get crd flamepools.flame.org flamerunners.flame.org
```

2. Operator healthy:

```bash
kubectl get deploy -n flame
kubectl get pods -n flame
kubectl logs -n flame deploy/flame-k8s-controller
```

3. Webhook registered:

```bash
kubectl get mutatingwebhookconfigurations | grep flame
```

## Upgrade strategy

Use release tags and install script with explicit version:

```bash
bash /tmp/install-operator.sh --tag v0.1.0 --namespace flame
```

Pinning versions avoids accidental behavior drift.

## Safe cleanup

Delete application workloads first, then pools/runners if required. Finalizers
protect against inconsistent deletion order.

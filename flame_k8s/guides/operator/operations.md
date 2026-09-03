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

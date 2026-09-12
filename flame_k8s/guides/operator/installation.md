# Operator Installation

This guide covers production-friendly installation of the operator and CRDs.

## Recommended: Remote install from release assets

No repository clone is required.

Install latest release:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/latest/download/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --namespace flame
```

Install pinned version:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --tag v0.1.4 --namespace flame
```

Useful flags:

- `--tag vX.Y.Z`: install an exact release.
- `--namespace flame`: operator namespace.
- `--secret-name flame-erlang-cookie`: Erlang cookie secret name.
- `--argocd-namespace argocd`: Argo CD namespace to patch when `argocd-cm` exists.
- `--disable-argocd-health`: skip automatic Argo CD health customization.
- `--repo owner/repo`: alternate release source.

What the installer does:

1. Resolves the release tag (`--tag` or latest).
2. Downloads `flame-k8s-manifests-<tag>.tar.gz` from release assets.
3. Creates or reuses cookie secret in operator namespace.
4. Applies namespace and CRDs.
5. Waits for CRDs to become `Established`.
6. Applies operator manifests with kustomize.
7. If Argo CD is detected, merges `.k8s/install/argocd/argocd-cm-flame-health.yaml` into `argocd-cm`.

The Argo CD customization manifest is intentionally stored outside `.k8s/install/manifests`. This prevents directory-based operator installs through Kustomize or Argo CD Applications from trying to manage `argocd-cm` as part of the operator application. The manifest targets the `argocd` namespace by default. If your Argo CD installation runs in a different namespace, use `--argocd-namespace` with the installer.

## Alternative: Direct YAML apply from release assets

For manual apply, use release asset URLs:

```bash
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/namespace.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/flamepool.crd.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/flamerunner.crd.yaml
kubectl wait --for=condition=Established crd/flamepools.flame.org --timeout=60s
kubectl wait --for=condition=Established crd/flamerunners.flame.org --timeout=60s
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/deployment.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/service.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/serviceaccount.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/clusterrole.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/clusterrolebinding.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.4/mutatingwebhookconfiguration.yaml
```

Use this mode only if your platform cannot run the installer script.

If Argo CD is present and you install manually, also merge the release asset `argocd-cm-flame-health.yaml` into the Argo CD namespace. That asset is intentionally separate from the operator Kustomize directory. The manifest is authored for the default `argocd` namespace, so change the namespace if your Argo CD installation uses a different one.

## Why remote install is stable

The release pipeline publishes all required installation assets on every tag:

- `flame-k8s-manifests-vX.Y.Z.tar.gz`
- all files from `.k8s/install/manifests/*.yaml`
- `scripts/install-operator.sh`

This guarantees a versioned and reproducible remote install path.

Audit reference:

- Workflow: `.github/workflows/release.yaml`
- Steps: `Generate release manifests for tagged image`, `Pack manifests`,
  `Create GitHub Release`

## Prerequisites

- `kubectl`
- Cluster access with permissions for CRDs, RBAC, webhooks, and namespace resources.
- `openssl` (required by installer script for cookie generation).

## Verify installation

```bash
kubectl get crd flamepools.flame.org flamerunners.flame.org
kubectl get deploy -n flame
kubectl get pods -n flame
```

If operator pods are `Running` and CRDs exist, installation is complete.

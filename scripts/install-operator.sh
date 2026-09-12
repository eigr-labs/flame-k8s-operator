#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY_OVERRIDE:-eigr-labs/flame-k8s-operator}"
namespace="flame"
secret_name="${COOKIE_SECRET_NAME:-flame-erlang-cookie}"
argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
enable_argocd_health="true"
manifest_dir=""
tag=""
tmp_dir=""

usage() {
  cat <<EOF
usage: $0 [--tag vX.Y.Z] [--namespace flame] [--manifest-dir PATH] [--secret-name NAME] [--repo owner/repo] [--argocd-namespace argocd] [--disable-argocd-health]

Examples:
  $0 --tag v0.1.0
  $0 --tag v0.1.0 --namespace flame
  $0 --manifest-dir .k8s/install/manifests --namespace flame
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --namespace)
      namespace="${2:-}"
      shift 2
      ;;
    --manifest-dir)
      manifest_dir="${2:-}"
      shift 2
      ;;
    --secret-name)
      secret_name="${2:-}"
      shift 2
      ;;
    --argocd-namespace)
      argocd_namespace="${2:-}"
      shift 2
      ;;
    --disable-argocd-health)
      enable_argocd_health="false"
      shift 1
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

ensure_cookie_secret() {
  local target_namespace="$1"
  local target_secret_name="$2"

  kubectl get namespace "$target_namespace" >/dev/null 2>&1 || kubectl create namespace "$target_namespace" >/dev/null

  if kubectl -n "$target_namespace" get secret "$target_secret_name" >/dev/null 2>&1; then
    echo "cookie secret '$target_secret_name' already exists in namespace '$target_namespace', reusing it"
    return 0
  fi

  local cookie
  cookie="$(openssl rand -hex 32)"
  kubectl -n "$target_namespace" create secret generic "$target_secret_name" --from-literal=cookie="$cookie" >/dev/null
  echo "created cookie secret '$target_secret_name' in namespace '$target_namespace'"
}

resolve_latest_tag() {
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' \
    | head -n 1
}

download_release_bundle() {
  local release_tag="$1"
  local asset_name="flame-k8s-manifests-${release_tag}.tar.gz"
  local asset_url="https://github.com/${repo}/releases/download/${release_tag}/${asset_name}"

  tmp_dir="$(mktemp -d)"
  trap '[[ -n "$tmp_dir" ]] && rm -rf "$tmp_dir"' EXIT

  curl -fsSL "$asset_url" -o "$tmp_dir/$asset_name"
  tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  manifest_dir="$tmp_dir/.k8s/install/manifests"
}

apply_argocd_health_customizations() {
  local install_root
  install_root="$(dirname "$manifest_dir")"
  local health_manifest="$install_root/argocd/argocd-cm-flame-health.yaml"
  local rendered_manifest="$health_manifest"
  local temp_manifest=""

  if [[ "$enable_argocd_health" != "true" ]]; then
    echo "argocd health customization disabled by flag"
    return 0
  fi

  if [[ ! -f "$health_manifest" ]]; then
    echo "argocd health manifest not found in $manifest_dir, skipping"
    return 0
  fi

  if ! kubectl get namespace "$argocd_namespace" >/dev/null 2>&1; then
    echo "argocd namespace '$argocd_namespace' not found, skipping argocd health customization"
    return 0
  fi

  if ! kubectl -n "$argocd_namespace" get configmap argocd-cm >/dev/null 2>&1; then
    echo "configmap 'argocd-cm' not found in namespace '$argocd_namespace', skipping argocd health customization"
    return 0
  fi

  if [[ "$argocd_namespace" != "argocd" ]]; then
    temp_manifest="$(mktemp)"
    sed "s/^  namespace: argocd$/  namespace: ${argocd_namespace}/" "$health_manifest" > "$temp_manifest"
    rendered_manifest="$temp_manifest"
  fi

  if kubectl -n "$argocd_namespace" apply --server-side --field-manager=flame-k8s-operator-install -f "$rendered_manifest" >/dev/null 2>&1; then
    echo "applied argocd flame health customizations in namespace '$argocd_namespace'"
  else
    echo "failed to apply argocd flame health customizations in namespace '$argocd_namespace', continuing operator installation" >&2
  fi

  if [[ -n "$temp_manifest" && -f "$temp_manifest" ]]; then
    rm -f "$temp_manifest"
  fi
}

require_cmd kubectl
require_cmd openssl

if [[ -z "$manifest_dir" ]]; then
  require_cmd curl
  require_cmd tar

  if [[ -z "$tag" ]]; then
    tag="$(resolve_latest_tag)"
  fi

  if [[ -z "$tag" ]]; then
    echo "unable to resolve release tag from GitHub for ${repo}" >&2
    exit 1
  fi

  download_release_bundle "$tag"
fi

if [[ ! -d "$manifest_dir" ]]; then
  echo "manifest directory not found: $manifest_dir" >&2
  exit 1
fi

ensure_cookie_secret "$namespace" "$secret_name"

kubectl apply -f "$manifest_dir/namespace.yaml"
kubectl apply -f "$manifest_dir/flamepool.crd.yaml"
kubectl apply -f "$manifest_dir/flamerunner.crd.yaml"
kubectl wait --for=condition=Established crd/flamepools.flame.org --timeout=60s
kubectl wait --for=condition=Established crd/flamerunners.flame.org --timeout=60s
kubectl apply -k "$manifest_dir"
apply_argocd_health_customizations

echo "operator install applied from $manifest_dir in namespace $namespace"

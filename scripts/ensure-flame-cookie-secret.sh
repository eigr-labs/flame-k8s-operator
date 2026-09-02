#!/usr/bin/env bash
set -euo pipefail

namespace="${1:-}"
secret_name="${2:-flame-erlang-cookie}"

if [[ -z "$namespace" ]]; then
  echo "usage: $0 <namespace> [secret-name]" >&2
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 1
}

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required" >&2
  exit 1
}

kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace" >/dev/null

if kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
  echo "cookie secret '$secret_name' already exists in namespace '$namespace', reusing it"
  exit 0
fi

cookie="$(openssl rand -hex 32)"
kubectl -n "$namespace" create secret generic "$secret_name" --from-literal=cookie="$cookie" >/dev/null

echo "created cookie secret '$secret_name' in namespace '$namespace'"

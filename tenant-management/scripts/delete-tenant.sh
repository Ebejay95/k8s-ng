#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tenant-id>"
  exit 1
fi

TENANT_ID="$1"
NS="tenant-${TENANT_ID}"

if ! [[ "${TENANT_ID}" =~ ^[a-z0-9-]+$ ]]; then
  echo "tenant-id must match ^[a-z0-9-]+$"
  exit 1
fi

echo "Deleting tenant namespace ${NS} (including tenant-scoped resources)..."
kubectl delete namespace "${NS}" --wait=true

echo "Done. Remove tenant DB separately if required by your DB policy."

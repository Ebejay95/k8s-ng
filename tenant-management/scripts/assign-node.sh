#!/usr/bin/env bash
set -euo pipefail

# assign-node.sh – Weist einem Tenant einen dedizierten Kubernetes-Node zu.
#
# Setzt Label + Taint, sodass NUR die Pods dieses Tenants (die das passende
# nodeSelector + die Toleration tragen) auf dem Node schedulen.
#
# Dieser Schritt ist die "Node-Ausrollung" je Tenant und kann sowohl per CLI
# als auch aus der Admin-App (ueber die Kubernetes-API / einen Job) gesteuert
# werden.
#
# Usage:
#   ./assign-node.sh <tenant-id> <node-name>
#   ./assign-node.sh <tenant-id> <node-name> --release   # Zuweisung aufheben

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <tenant-id> <node-name> [--release]"
  exit 1
fi

TENANT_ID="$1"
NODE_NAME="$2"
ACTION="${3:-assign}"
LABEL_KEY="tenant.navosec.io/dedicated"
TAINT_KEY="tenant.navosec.io/dedicated"

if ! [[ "${TENANT_ID}" =~ ^[a-z0-9-]+$ ]]; then
  echo "tenant-id must match ^[a-z0-9-]+$"
  exit 1
fi

if ! kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
  echo "Node ${NODE_NAME} existiert nicht."
  exit 1
fi

if [[ "${ACTION}" == "--release" ]]; then
  echo "Releasing node ${NODE_NAME} from tenant ${TENANT_ID}"
  kubectl label node "${NODE_NAME}" "${LABEL_KEY}-" --overwrite >/dev/null
  kubectl taint node "${NODE_NAME}" "${TAINT_KEY}:NoSchedule-" >/dev/null 2>&1 || true
  echo "Node ${NODE_NAME} freigegeben."
  exit 0
fi

# Schutz: Node darf nicht bereits einem ANDEREN Tenant gehoeren.
CURRENT="$(kubectl get node "${NODE_NAME}" -o jsonpath="{.metadata.labels.tenant\.navosec\.io/dedicated}" 2>/dev/null || true)"
if [[ -n "${CURRENT}" && "${CURRENT}" != "${TENANT_ID}" ]]; then
  echo "Node ${NODE_NAME} ist bereits Tenant '${CURRENT}' zugewiesen. Abbruch."
  exit 1
fi

echo "Assigning node ${NODE_NAME} to tenant ${TENANT_ID} (Label + Taint)"
kubectl label node "${NODE_NAME}" "${LABEL_KEY}=${TENANT_ID}" --overwrite >/dev/null
kubectl taint node "${NODE_NAME}" "${TAINT_KEY}=${TENANT_ID}:NoSchedule" --overwrite >/dev/null

echo "Node ${NODE_NAME} ist jetzt dediziert fuer Tenant ${TENANT_ID}."

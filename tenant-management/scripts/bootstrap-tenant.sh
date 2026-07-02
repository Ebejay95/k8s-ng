#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tenant-id> [node-name]"
  echo "  node-name: optionaler Worker-Node, der diesem Tenant dediziert"
  echo "             zugewiesen wird (Label + Taint). Ohne Angabe muss der"
  echo "             Node vorher per scripts/assign-node.sh gepinnt werden."
  exit 1
fi

TENANT_ID="$1"
NODE_NAME="${2:-${NODE_NAME:-}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL_DIR="${ROOT_DIR}/templates"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Vollstaendige Tenant-Trennung: jeder Tenant erhaelt eigenen Namespace,
# eigene App, eigene DB, eigenen Ingress-Host, eigenen Node und eigenes
# (verpflichtend dediziertes) Ollama. Konfigurierbar via ENV.
DOMAIN="${DOMAIN:-meinedomain.de}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/yourorg/navosec-web:latest}"
APP_REPLICAS="${APP_REPLICAS:-2}"
TENANT_DB_STORAGE="${TENANT_DB_STORAGE:-10Gi}"
# Referenz-DB (In-Cluster, Selektor-basiert). Der read-only Connection-String
# wird aus dem reference_reader-Passwort zusammengebaut (Env oder Secret).
REFERENCE_READER_PASSWORD="${REFERENCE_READER_PASSWORD:-}"

if ! [[ "${TENANT_ID}" =~ ^[a-z0-9-]+$ ]]; then
  echo "tenant-id must match ^[a-z0-9-]+$"
  exit 1
fi

apply_tpl() {
  local file="$1"
  sed \
    -e "s/__TENANT_ID__/${TENANT_ID}/g" \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s|__APP_IMAGE__|${APP_IMAGE}|g" \
    -e "s/__APP_REPLICAS__/${APP_REPLICAS}/g" \
    -e "s/__TENANT_DB_STORAGE__/${TENANT_DB_STORAGE}/g" \
    -e "s/__RQ_REQUESTS_CPU__/2/g" \
    -e "s/__RQ_REQUESTS_MEMORY__/4Gi/g" \
    -e "s/__RQ_LIMITS_CPU__/4/g" \
    -e "s/__RQ_LIMITS_MEMORY__/8Gi/g" \
    -e "s/__RQ_PODS__/20/g" \
    -e "s/__RQ_PVCS__/5/g" \
    -e "s/__OLLAMA_STORAGE__/40Gi/g" \
    -e "s/__OLLAMA_REQ_CPU__/1/g" \
    -e "s/__OLLAMA_REQ_MEM__/8Gi/g" \
    -e "s/__OLLAMA_REQ_GPU__/1/g" \
    -e "s/__OLLAMA_LIM_CPU__/3/g" \
    -e "s/__OLLAMA_LIM_MEM__/16Gi/g" \
    -e "s/__OLLAMA_LIM_GPU__/1/g" \
    "${file}" | kubectl apply -f -
}

echo "[1/6] Pin dedicated node for tenant (Label + Taint)"
if [[ -n "${NODE_NAME}" ]]; then
  NODE_NAME="${NODE_NAME}" TENANT_ID="${TENANT_ID}" "${SCRIPT_DIR}/assign-node.sh" "${TENANT_ID}" "${NODE_NAME}"
else
  echo "  -> Kein NODE_NAME angegeben. Stelle sicher, dass mindestens ein Node"
  echo "     das Label tenant.navosec.io/dedicated=${TENANT_ID} traegt,"
  echo "     sonst bleiben die Tenant-Pods Pending."
fi

echo "[2/6] Create tenant namespace"
apply_tpl "${TPL_DIR}/namespace.yaml.tpl"

echo "[3/6] Apply tenant network isolation"
apply_tpl "${TPL_DIR}/networkpolicies.yaml.tpl"

echo "[4/6] Apply tenant quotas and limits"
apply_tpl "${TPL_DIR}/limits-and-quotas.yaml.tpl"

echo "[5/6] Provision in-cluster tenant DB (generated password) + deploy app"
# DB-Passwort einmalig generieren (idempotent: vorhandenes beibehalten).
NS="tenant-${TENANT_ID}"
if kubectl get secret tenant-db-credentials -n "${NS}" >/dev/null 2>&1; then
  TENANT_DB_PASSWORD="$(kubectl get secret tenant-db-credentials -n "${NS}" -o jsonpath='{.data.postgres-password}' | base64 -d)"
else
  TENANT_DB_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
fi
kubectl create secret generic tenant-db-credentials \
  --namespace "${NS}" \
  --from-literal=postgres-password="${TENANT_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic tenant-db-secret \
  --namespace "${NS}" \
  --from-literal=ConnectionStrings__DefaultConnection="Host=tenant-db;Port=5432;Database=navosec_tenant;Username=navosec_tenant;Password=${TENANT_DB_PASSWORD}" \
  --from-literal=ConnectionStrings__Reference="Host=reference-db.reference.svc.cluster.local;Port=5432;Database=reference;Username=reference_reader;Password=${REFERENCE_READER_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
apply_tpl "${TPL_DIR}/db.yaml.tpl"
apply_tpl "${TPL_DIR}/app.yaml.tpl"

echo "[6/6] Deploy mandatory dedicated ollama for tenant"
apply_tpl "${TPL_DIR}/ollama-dedicated.yaml.tpl"

echo "Done. Tenant ${TENANT_ID} is fully isolated (node, namespace, app, db, ingress, ollama)."

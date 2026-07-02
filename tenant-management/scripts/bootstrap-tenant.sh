#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <tenant-id> <db-item-id> [node-name]"
  echo "  node-name: optionaler Worker-Node, der diesem Tenant dediziert"
  echo "             zugewiesen wird (Label + Taint). Ohne Angabe muss der"
  echo "             Node vorher per scripts/assign-node.sh gepinnt werden."
  exit 1
fi

TENANT_ID="$1"
DB_ITEM_ID="$2"
NODE_NAME="${3:-${NODE_NAME:-}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL_DIR="${ROOT_DIR}/templates"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Vollstaendige Tenant-Trennung: jeder Tenant erhaelt eigenen Namespace,
# eigene App, eigene DB, eigenen Ingress-Host, eigenen Node und eigenes
# (verpflichtend dediziertes) Ollama. Konfigurierbar via ENV.
DOMAIN="${DOMAIN:-meinedomain.de}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/yourorg/navosec-web:latest}"
APP_REPLICAS="${APP_REPLICAS:-2}"
# Stammdaten-/Referenz-DB (Tenant liest read-only). PLATZHALTER-Werte:
# echte DB-Adresse + Vault-Item spaeter setzen.
REFERENCE_DB_CIDR="${REFERENCE_DB_CIDR:-10.0.1.201/32}"
REFERENCE_DB_ITEM_ID="${REFERENCE_DB_ITEM_ID:-CHANGE_ME_REFERENCE_ITEM_ID}"

if ! [[ "${TENANT_ID}" =~ ^[a-z0-9-]+$ ]]; then
  echo "tenant-id must match ^[a-z0-9-]+$"
  exit 1
fi

apply_tpl() {
  local file="$1"
  sed \
    -e "s/__TENANT_ID__/${TENANT_ID}/g" \
    -e "s/__DB_ITEM_ID__/${DB_ITEM_ID}/g" \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s|__APP_IMAGE__|${APP_IMAGE}|g" \
    -e "s/__APP_REPLICAS__/${APP_REPLICAS}/g" \
    -e "s/__TENANT_DB_CIDR__/10.0.1.200\/32/g" \
    -e "s|__REFERENCE_DB_CIDR__|${REFERENCE_DB_CIDR}|g" \
    -e "s/__REFERENCE_DB_ITEM_ID__/${REFERENCE_DB_ITEM_ID}/g" \
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

echo "[5/6] Create tenant db secret sync (ExternalSecret) + deploy app"
apply_tpl "${TPL_DIR}/db-externalsecret.yaml.tpl"
apply_tpl "${TPL_DIR}/app.yaml.tpl"

echo "[6/6] Deploy mandatory dedicated ollama for tenant"
apply_tpl "${TPL_DIR}/ollama-dedicated.yaml.tpl"

echo "Done. Tenant ${TENANT_ID} is fully isolated (node, namespace, app, db, ingress, ollama)."

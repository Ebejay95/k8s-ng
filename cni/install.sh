#!/usr/bin/env bash
# Cilium-Bootstrap-Installation (Helm).
#
# Das CNI muss VOR allen anderen Workloads laufen und wird daher NICHT ueber
# Kustomize/ArgoCD verwaltet, sondern einmalig per Helm installiert. Danach
# werden App-Workloads via ArgoCD/Kustomize ausgerollt.
#
# Voraussetzungen: helm, kubectl, Kontext auf dem Zielcluster.
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"
VALUES_FILE="$(dirname "$0")/cilium-values.yaml"

echo ">> Helm-Repo hinzufuegen/aktualisieren"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium

echo ">> Cilium ${CILIUM_VERSION} installieren/aktualisieren"
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  -f "${VALUES_FILE}"

echo ">> Auf Rollout warten"
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s

echo ">> Status (optional): cilium status --wait   (benoetigt cilium-CLI)"
echo ">> Fertig."

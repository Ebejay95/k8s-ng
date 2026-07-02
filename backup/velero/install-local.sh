#!/usr/bin/env bash
# Velero-Installation fuer den LOKALEN Docker-Desktop-Cluster.
# Backup-Ziel: In-Cluster-MinIO (siehe k8s-ng/minio/). Node-Agent (Kopia)
# sichert PersistentVolumes dateibasiert (hostpath kann keine Snapshots).
set -euo pipefail

VELERO_PLUGIN_AWS="${VELERO_PLUGIN_AWS:-velero/velero-plugin-for-aws:v1.12.1}"
S3_URL="${S3_URL:-http://minio.minio.svc.cluster.local:9000}"
BUCKET="${BUCKET:-velero}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# S3-kompatible Zugangsdaten (entsprechen k8s-ng/minio/10-secret.yaml).
cat >"${WORKDIR}/credentials-velero" <<EOF
[default]
aws_access_key_id=${MINIO_USER:-minioadmin}
aws_secret_access_key=${MINIO_PASSWORD:-minioadmin123}
EOF

velero install \
  --provider aws \
  --plugins "${VELERO_PLUGIN_AWS}" \
  --bucket "${BUCKET}" \
  --secret-file "${WORKDIR}/credentials-velero" \
  --use-node-agent \
  --use-volume-snapshots=false \
  --backup-location-config "region=minio,s3ForcePathStyle=true,s3Url=${S3_URL}" \
  --namespace velero

echo "Velero installiert. Status: velero backup-location get"

# Velero – Installation & Backup-Ziel

Velero-Core (Deployment + CRDs + Node-Agent) wird als Bootstrap-Komponente
installiert, NICHT über das Kustomize-`base` (dort liegen nur die
`Schedule`-Objekte in `backup/`).

## Lokal (Docker Desktop)

Backup-Ziel ist das In-Cluster-MinIO aus `k8s-ng/minio/` (nur im
`environments/local`-Overlay enthalten):

```bash
kubectl apply -k k8s-ng/minio          # MinIO + Bucket 'velero'
bash k8s-ng/backup/velero/install-local.sh
kubectl -n velero rollout status deploy/velero
velero backup create test --include-namespaces reference --wait
velero backup get
```

## Prod / Staging

MinIO/S3 läuft **separat vom Cluster** (per Terraform bereitgestellt, siehe
`terraform/`). Velero zeigt dann auf dessen Endpoint statt auf das
In-Cluster-MinIO:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.12.1 \
  --bucket navosec-velero \
  --secret-file ./credentials-velero \
  --use-node-agent \
  --use-volume-snapshots=false \
  --backup-location-config region=<region>,s3ForcePathStyle=true,s3Url=https://<minio-endpoint> \
  --namespace velero
```

Zugangsdaten in prod aus Vaultwarden (ExternalSecret) statt statischer Datei.

Die `Schedule`-Objekte in `backup/20-velero-schedule-example.yaml`
(`cluster-daily`, `tenants-daily`) greifen automatisch, sobald Velero + CRDs
vorhanden sind.

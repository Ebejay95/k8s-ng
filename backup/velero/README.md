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

MinIO/S3 läuft **separat vom Cluster** auf einer eigenen Hetzner-VM mit eigenem
Volume (per Terraform: `terraform/hetzner/backup-storage.tf`,
`enable_backup_storage = true`). Velero (im Cluster) sichert über das private
Netz dorthin, sodass ein Cluster-Verlust die Backups nicht mitnimmt.

Relevante Terraform-Outputs:

- `backup_minio_s3_endpoint` → z. B. `http://10.0.1.240:9000` (privates Netz)
- `backup_minio_bucket` → `velero`
- Zugangsdaten: `backup_minio_root_user` / `TF_VAR_backup_minio_root_password`

```bash
# credentials-velero (Access/Secret Key = MinIO Root-User/-Passwort)
cat > credentials-velero <<'EOF'
[default]
aws_access_key_id=velero
aws_secret_access_key=<BACKUP_MINIO_ROOT_PASSWORD>
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.12.1 \
  --bucket velero \
  --secret-file ./credentials-velero \
  --use-node-agent \
  --use-volume-snapshots=false \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://10.0.1.240:9000 \
  --namespace velero
```

Zugangsdaten in prod idealerweise aus Vaultwarden (ExternalSecret) statt
statischer Datei. Der Backup-Server-Endpoint ist nur aus dem Cluster-Subnetz
erreichbar (Firewall in `backup-storage.tf`).

Die `Schedule`-Objekte in `backup/20-velero-schedule-example.yaml`
(`cluster-daily`, `tenants-daily`) greifen automatisch, sobald Velero + CRDs
vorhanden sind.

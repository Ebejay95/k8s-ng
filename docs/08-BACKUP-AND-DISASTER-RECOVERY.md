# 08-BACKUP-AND-DISASTER-RECOVERY.md – Velero, etcd Snapshots, Database Backups

## Strategie

**3-Schichten Backup:**
1. **etcd Snapshots** – Kubernetes State (Deployment, Secret, ConfigMap, etc.)
2. **Persistent Volume Backups** – Data Volumes (PostgreSQL, Minio)
3. **Database Backups** – pg_dump pro Tenant-DB

---

## 1. Velero (etcd + PV Backups)

```yaml
# backup/velero-install.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: velero

---
# Velero Helm Chart
# helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
# helm install velero vmware-tanzu/velero -f values.yaml

# values.yaml:
configuration:
  backupStorageLocation:
    bucket: navosec-velero-backups
    provider: aws  # oder s3 mit endpoint
    config:
      s3Url: https://s3.meinedomain.de  # Hetzner S3
      region: eu-central
      s3ForcePathStyle: "true"

  volumeSnapshotLocation:
    provider: aws
    config:
      snapshotLocation: eu-central

schedules:
  daily:
    schedule: "0 2 * * *"  # 2 AM täglich
    template:
      ttl: "720h"  # Keep 30 days
      includedNamespaces:
        - navosec-prod
        - observability
        - argocd
      snapshotVolumes: true

  weekly:
    schedule: "0 3 * * 0"  # Sundays 3 AM
    template:
      ttl: "8760h"  # Keep 1 year
      includedNamespaces:
        - navosec-prod
      snapshotVolumes: true
```

---

## 2. PostgreSQL Backups (pro Tenant)

```bash
#!/bin/bash
# backup/postgres-backup-cronjob.sh
# Wird via Kubernetes CronJob täglich ausgeführt

set -euo pipefail

TENANT_ID=${1:-}
if [ -z "$TENANT_ID" ]; then
  echo "Usage: $0 <tenant-id>"
  exit 1
fi

# Hole Credentials aus Secret
DB_HOST=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.host}' | base64 -d)
DB_PORT=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.port}' | base64 -d)
DB_USER=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.username}' | base64 -d)
DB_PASSWORD=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.password}' | base64 -d)
DB_NAME=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.database}' | base64 -d)

# Backup
BACKUP_FILE="backup-${TENANT_ID}-$(date +%Y%m%d-%H%M%S).sql.gz"

PGPASSWORD="$DB_PASSWORD" pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  "$DB_NAME" | gzip > "/tmp/${BACKUP_FILE}"

echo "✅ Backup created: $BACKUP_FILE"

# Upload to S3 (Minio/Hetzner)
aws s3 cp "/tmp/${BACKUP_FILE}" \
  "s3://navosec-backups/postgres/${TENANT_ID}/" \
  --endpoint-url https://s3.meinedomain.de

echo "✅ Uploaded to S3"

# Cleanup lokal
rm "/tmp/${BACKUP_FILE}"

# Cleanup old backups (> 30 days)
aws s3 rm \
  "s3://navosec-backups/postgres/${TENANT_ID}/" \
  --endpoint-url https://s3.meinedomain.de \
  --recursive \
  --exclude "*" \
  --include "backup-*" \
  --older-than 30
```

```yaml
# backup/postgres-backup-cronjob.yaml

apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup-daily
  namespace: navosec-prod
spec:
  schedule: "0 3 * * *"  # Täglich 3 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-manager
          restartPolicy: OnFailure
          containers:
            - name: postgres-backup
              image: amazon/aws-cli:latest
              command:
                - /bin/sh
                - -c
                - |
                  # Für alle Tenants Backup erstellen
                  TENANTS=$(kubectl get secrets -n navosec-prod \
                    -l tenant-id -o jsonpath='{.items[*].metadata.labels.tenant-id}')

                  for TENANT in $TENANTS; do
                    echo "Backing up tenant: $TENANT"
                    # Rufe Backup-Script auf
                    /scripts/postgres-backup-cronjob.sh "$TENANT"
                  done
              env:
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: access-key
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: secret-key
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
          volumes:
            - name: scripts
              configMap:
                name: backup-scripts
                defaultMode: 0755
```

---

## 3. Etcd Backup (Talos)

```bash
#!/bin/bash
# backup/etcd-backup-hetzner.sh
# Wird auf Hetzner Control Plane Node ausgeführt

# SSH zur Control Plane
ssh talos@control-plane-1.meinedomain.de <<'EOF'
  # Hole Etcd Snapshot
  sudo talosctl etcd backup -n $(hostname -f)

  # Snapshots sind in /var/lib/etcd/member/snap/
  # Kopiere zu S3
  sudo aws s3 cp /var/lib/etcd/member/snap/db-* \
    s3://navosec-backups/etcd/ \
    --endpoint-url https://s3.meinedomain.de

  # Cleanup alte Snapshots (> 30 Tage)
  find /var/lib/etcd/member/snap/db-* -mtime +30 -delete
EOF
```

---

## 4. Restore Procedures

### Restore Tenant Database

```bash
#!/bin/bash
# backup/restore-tenant-db.sh

TENANT_ID=$1
BACKUP_FILE=$2

if [ -z "$TENANT_ID" ] || [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <tenant-id> <backup-file>"
  exit 1
fi

# Download vom S3
aws s3 cp "s3://navosec-backups/postgres/${TENANT_ID}/${BACKUP_FILE}" \
  "/tmp/${BACKUP_FILE}" \
  --endpoint-url https://s3.meinedomain.de

# Hole DB Credentials
DB_HOST=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.host}' | base64 -d)
DB_USER=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.username}' | base64 -d)
DB_PASSWORD=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.password}' | base64 -d)
DB_NAME=$(kubectl get secret tenant-${TENANT_ID}-db -o jsonpath='{.data.database}' | base64 -d)

# Restore
PGPASSWORD="$DB_PASSWORD" gunzip -c "/tmp/${BACKUP_FILE}" | psql \
  -h "$DB_HOST" \
  -U "$DB_USER" \
  -d "$DB_NAME"

echo "✅ Database restored from $BACKUP_FILE"
```

### Restore Kubernetes Cluster

```bash
# Velero restore
velero restore create --from-backup daily-20250101

# Warte auf Restore
velero restore describe daily-20250101-20250102-121234 --details
```

---

## 5. Backup Storage (S3 auf Hetzner)

```hcl
# terraform/hetzner/backup-storage.tf

# S3 Bucket auf Hetzner
resource "hcloud_s3_bucket" "backups" {
  name       = "navosec-backups-prod"
  labels     = local.common_labels
}

# S3 Credentials
resource "hcloud_s3_credentials" "backup_user" {
  bucket_id = hcloud_s3_bucket.backups.id
  access_key {
    status = "Active"
  }
}

# Output für Kubernetes Secret
output "s3_backup_credentials" {
  value = {
    endpoint       = "s3.meinedomain.de"
    access_key     = hcloud_s3_credentials.backup_user.access_key[0].id
    secret_key     = hcloud_s3_credentials.backup_user.access_key[0].secret
    bucket         = hcloud_s3_bucket.backups.name
  }
  sensitive = true
}
```

---

## 6. Backup Verification (Recovery Tests)

```yaml
# backup/backup-verify-cronjob.yaml

apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-verify-weekly
  namespace: navosec-prod
spec:
  schedule: "0 4 * * 0"  # Sonntag 4 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-manager
          restartPolicy: OnFailure
          containers:
            - name: verify
              image: backup-verify:latest
              command:
                - /bin/sh
                - -c
                - |
                  # 1. Prüfe ob Backups existieren
                  aws s3 ls s3://navosec-backups/ \
                    --endpoint-url https://s3.meinedomain.de

                  # 2. Download random Backup
                  BACKUP=$(aws s3 ls s3://navosec-backups/postgres/ \
                    --endpoint-url https://s3.meinedomain.de | \
                    tail -1 | awk '{print $NF}')

                  # 3. Prüfe ob gzip-valid
                  gunzip -t "/tmp/${BACKUP}" 2>/dev/null && \
                    echo "✅ Backup is valid" || \
                    echo "❌ Backup is corrupted"

                  # 4. Send Alert
                  curl -X POST https://slack.com/api/chat.postMessage \
                    -d 'channel=backup-alerts&text=Backup Verification Complete'
```

---

## 7. Disaster Recovery Plan

| Szenario | RTO | Aktion |
|----------|-----|--------|
| Pod Crash | 1m | Health Check → Restart |
| Node Failure | 5m | Pod reschedule zu andere Node |
| Datenbank beschädigt | 30m | Restore aus Backup |
| Cluster totalverlust | 2h | Velero restore in neu Cluster |
| Tenant Datenverlust | 1h | Restore einzelne Tenant-DB |
| Ransomware/Malware | 4h | Isolieren Tenant, restore altes Backup |

---

## 8. Checkliste

- [ ] Velero installiert
- [ ] etcd Snapshots täglich
- [ ] PostgreSQL Backups pro Tenant
- [ ] S3 Backup Storage konfiguriert
- [ ] Backup Verification CronJob
- [ ] Recovery Tests monatlich
- [ ] Alerting auf Backup-Fehler
- [ ] Backups sind verschlüsselt
- [ ] Backups sind off-site (Hetzner Storage)

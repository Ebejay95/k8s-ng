#!/bin/bash
# cloud-init-minio.sh – Installiert MinIO als Velero-Backup-Ziel auf separater VM.
# Wird von backup-storage.tf via templatefile() gerendert.
set -euo pipefail

DEVICE="/dev/disk/by-id/scsi-0HC_Volume_${volume_id}"
MOUNT="/mnt/backup"

# ── Backup-Volume einhaengen ─────────────────────────────────────────────
for _ in $(seq 1 30); do
  [ -e "$DEVICE" ] && break
  sleep 2
done

mkdir -p "$MOUNT"
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -F "$DEVICE"
fi
if ! grep -q "$MOUNT" /etc/fstab; then
  echo "$DEVICE $MOUNT ext4 defaults,nofail 0 0" >> /etc/fstab
fi
mount -a
mkdir -p "$MOUNT/data"

# ── Docker installieren ──────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl
systemctl enable --now docker

# ── MinIO starten ──────────────────────────────────────────────────────
docker rm -f minio >/dev/null 2>&1 || true
docker run -d --name minio --restart always \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER='${minio_root_user}' \
  -e MINIO_ROOT_PASSWORD='${minio_root_password}' \
  -v "$MOUNT/data":/data \
  '${minio_image}' server /data --console-address ":9001"

# ── Auf MinIO warten und Bucket anlegen ─────────────────────────────────
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker run --rm --network host \
  -e MC_HOST_local="http://${minio_root_user}:${minio_root_password}@127.0.0.1:9000" \
  '${mc_image}' mb --ignore-existing "local/${bucket}"

# backup-storage.tf – Separater MinIO-Backup-Server (ausserhalb des K8s-Clusters)
#
# Bewusst getrennt vom Cluster: eigene VM + eigenes Hetzner-Volume. Velero
# (im Cluster, node-agent/fs-backup) sichert nach hier ueber das private Netz.
# So ueberlebt das Backup einen kompletten Cluster-Verlust.

# ── Separates Volume fuer die Backup-Daten ──────────────────────────────
resource "hcloud_volume" "backup" {
  count             = var.enable_backup_storage ? 1 : 0
  name              = "${local.cluster_name}-backup-vol"
  size              = var.backup_volume_size_gb
  location          = var.location
  format            = "ext4"
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "purpose" = "backup", "service" = "minio" }
  )
}

# ── Cloud-Init (MinIO-Installation) ─────────────────────────────────────
locals {
  backup_minio_init = var.enable_backup_storage ? templatefile("${path.module}/cloud-init-minio.sh", {
    volume_id           = hcloud_volume.backup[0].id
    minio_root_user     = var.backup_minio_root_user
    minio_root_password = var.backup_minio_root_password
    minio_image         = var.backup_minio_image
    mc_image            = var.backup_mc_image
    bucket              = var.backup_bucket
  }) : ""
}

# ── Backup-Server ───────────────────────────────────────────────────────
resource "hcloud_server" "backup" {
  count             = var.enable_backup_storage ? 1 : 0
  name              = "${local.cluster_name}-backup"
  image             = "ubuntu-24.04"
  server_type       = var.backup_server_type
  location          = var.location
  ssh_keys          = [hcloud_ssh_key.default.id]
  firewall_ids      = [hcloud_firewall.backup[0].id]
  user_data         = base64encode(local.backup_minio_init)
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "role" = "backup", "service" = "minio" }
  )

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_server_network" "backup" {
  count      = var.enable_backup_storage ? 1 : 0
  server_id  = hcloud_server.backup[0].id
  network_id = hcloud_network.main.id
  ip         = var.backup_private_ip
}

resource "hcloud_volume_attachment" "backup" {
  count     = var.enable_backup_storage ? 1 : 0
  volume_id = hcloud_volume.backup[0].id
  server_id = hcloud_server.backup[0].id
  automount = false
}

# ── Eigene Firewall: MinIO-API nur aus dem privaten Subnetz, SSH via Bastion ──
resource "hcloud_firewall" "backup" {
  count       = var.enable_backup_storage ? 1 : 0
  name        = "${local.cluster_name}-backup-fw"
  description = "Firewall fuer MinIO-Backup-Server ${local.cluster_name}"

  labels = local.common_labels

  # MinIO S3 API (9000) – nur aus dem Cluster-Subnetz
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "9000"
    source_ips = [var.subnet_ip_range]
  }

  # MinIO Console (9001) – nur aus dem Cluster-Subnetz (fuer Admin ueber Bastion-Tunnel)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "9001"
    source_ips = [var.subnet_ip_range]
  }

  # SSH – nur via Bastion/Admin
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.bastion_ssh_cidrs
  }
}

# ── Outputs ─────────────────────────────────────────────────────────────
output "backup_minio_private_ip" {
  description = "Private IP des MinIO-Backup-Servers"
  value       = try(hcloud_server_network.backup[0].ip, null)
}

output "backup_minio_s3_endpoint" {
  description = "S3-Endpoint fuer die Velero BackupStorageLocation (s3Url)"
  value       = var.enable_backup_storage ? "http://${var.backup_private_ip}:9000" : null
}

output "backup_minio_bucket" {
  description = "Velero-Bucket auf dem Backup-Server"
  value       = var.backup_bucket
}

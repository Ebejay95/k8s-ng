# backup-storage-variables.tf – Variablen fuer den separaten MinIO-Backup-Server
#
# Ziel: Ein vom Kubernetes-Cluster getrennter Speicherplatz (eigene VM + eigenes
# Volume) als S3-kompatibles Velero-Backup-Ziel. Bewusst NICHT im Cluster, damit
# Cluster-Verlust die Backups nicht mitnimmt.

variable "enable_backup_storage" {
  description = "Separaten MinIO-Backup-Server (ausserhalb K8s) als Velero-Ziel provisionieren?"
  type        = bool
  default     = false # In prod auf true setzen
}

variable "backup_server_type" {
  description = "Hetzner Server Type fuer den MinIO-Backup-Server"
  type        = string
  default     = "cx22" # 2 vCPU, 4 GB RAM – reicht fuer MinIO als Backup-Ziel
}

variable "backup_volume_size_gb" {
  description = "Groesse des separaten Backup-Volumes (GB) fuer die Backup-Daten"
  type        = number
  default     = 100
}

variable "backup_private_ip" {
  description = "Private IP des Backup-Servers im Subnetz (getrennt vom DB-Bereich)"
  type        = string
  default     = "10.0.1.240"
}

variable "backup_minio_root_user" {
  description = "MinIO Root-User (Access Key) fuer das Backup-Ziel"
  type        = string
  default     = "velero"
}

variable "backup_minio_root_password" {
  description = "MinIO Root-Passwort (Secret Key). Ueber TF_VAR_backup_minio_root_password setzen, NICHT hier hardcoden."
  type        = string
  sensitive   = true
}

variable "backup_bucket" {
  description = "Bucket-Name fuer Velero-Backups"
  type        = string
  default     = "velero"
}

variable "backup_minio_image" {
  description = "MinIO Server Image"
  type        = string
  default     = "minio/minio:RELEASE.2024-01-16T16-07-38Z"
}

variable "backup_mc_image" {
  description = "MinIO Client (mc) Image fuer Bucket-Erstellung"
  type        = string
  default     = "minio/mc:RELEASE.2024-01-13T08-44-48Z"
}

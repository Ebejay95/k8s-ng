# hetzner-postgresql-variables.tf – PostgreSQL-spezifische Variablen

variable "enable_external_postgres" {
  description = "PostgreSQL auf externen Hetzner-Servern (außerhalb K8s)? Standardmaessig AUS: alle DBs (admin/reference/tenant) laufen jetzt als StatefulSets im Cluster. Nur auf true setzen, wenn wieder externe DB-VMs gewuenscht sind."
  type        = bool
  default     = false  # DBs laufen in-cluster (admin-db/reference-db/tenant-db StatefulSets)
}

variable "postgres_server_type" {
  description = "Hetzner Server Type für PostgreSQL"
  type        = string
  default     = "cx41"  # 4 vCPU, 16 GB RAM (~€10/Monat)
}

variable "postgres_replica_count" {
  description = "Anzahl PostgreSQL Replicas (für HA mit Patroni)"
  type        = number
  default     = 2
}

variable "postgres_version" {
  description = "PostgreSQL Version"
  type        = string
  default     = "16"
}

variable "postgres_storage_size_gb" {
  description = "Volume Size für PostgreSQL (wird via Hetzner Volume attached)"
  type        = number
  default     = 500  # 500GB für alle Tenants oder per Tenant
}

# ──────────────────────────────────────────────────────────────────
# TENANT-DATABASE STRATEGIE
# ──────────────────────────────────────────────────────────────────

variable "tenant_database_strategy" {
  description = "Wie Tenant-Daten getrennt werden"
  type        = string
  default     = "per_tenant"  # per_tenant, per_group, shared
  validation {
    condition     = contains(["per_tenant", "per_group", "shared"], var.tenant_database_strategy)
    error_message = "Must be per_tenant, per_group, or shared."
  }
}

# Strategie "per_tenant": Jeder Tenant hat eigene Datenbank
# Strategie "per_group": Kundengruppen teilen sich eine DB (z.B. 10 kleine Kunden in einer DB)
# Strategie "shared": Alle Tenants in einer DB (kostengünstig, aber weniger Isolation)

variable "tenant_group_size" {
  description = "Tenants pro Database (falls strategy=per_group)"
  type        = number
  default     = 10  # z.B. 10 kleine Kunden teilen sich eine DB
}

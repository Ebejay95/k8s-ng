# hetzner-postgresql.tf – PostgreSQL Cluster für Multi-Tenant Datenbanken

# Strategie:
# Option A: Shared PostgreSQL (alle Tenants in einer Instanz)
# Option B: PostgreSQL per Tenant/Kundengruppe (diese Datei)
#
# Wir implementieren Option B mit Self-Hosted PostgreSQL auf Hetzner Servern.
# Warum: Hetzner hat kein Managed PostgreSQL, also deployieren wir via Docker/K8s
# oder externe VMs. Für simplicity: PostgreSQL auf separate Hetzner Nodes mit HA (Patroni)

# ──────────────────────────────────────────────────────────────────
# OPTION: PostgreSQL Server Nodes (Separate VMs außerhalb K8s)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_server" "postgres_primary" {
  count             = var.enable_external_postgres ? 1 : 0
  name              = "${local.cluster_name}-postgres-primary"
  image             = "ubuntu-24.04"
  server_type       = var.postgres_server_type # z.B. "cx41" (4 vCPU, 16 GB RAM)
  location          = var.location
  ssh_keys          = [hcloud_ssh_key.default.id]
  firewall_ids      = [hcloud_firewall.kubernetes.id]
  user_data         = base64encode(local.postgres_primary_init)
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "service" = "postgresql", "role" = "primary" }
  )

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_server_network" "postgres_primary" {
  count     = var.enable_external_postgres ? 1 : 0
  server_id = hcloud_server.postgres_primary[0].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.200"
}

# PostgreSQL Replicas (für HA via Patroni)
resource "hcloud_server" "postgres_replica" {
  count              = var.enable_external_postgres ? var.postgres_replica_count : 0
  name               = "${local.cluster_name}-postgres-replica-${count.index + 1}"
  image              = "ubuntu-24.04"
  server_type        = var.postgres_server_type
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.kubernetes.id]
  automount          = false

  labels = merge(
    local.common_labels,
    { "service" = "postgresql", "role" = "replica", "index" = count.index }
  )

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_server_network" "postgres_replica" {
  count     = var.enable_external_postgres ? var.postgres_replica_count : 0
  server_id = hcloud_server.postgres_replica[count.index].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.${210 + count.index}"  # 10.0.1.210, 10.0.1.211, ...
}

# ──────────────────────────────────────────────────────────────────
# FIREWALL RULE: PostgreSQL Traffic (5432)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_firewall_rule" "postgres" {
  count             = var.enable_external_postgres ? 1 : 0
  firewall_id       = hcloud_firewall.kubernetes.id
  direction         = "in"
  protocol          = "tcp"
  port              = "5432"
  source_ips        = [var.subnet_ip_range]  # Nur aus Private Network
  destination_ips   = []

  depends_on = [hcloud_firewall.kubernetes]
}

# ──────────────────────────────────────────────────────────────────
# CLOUD-INIT: PostgreSQL Installation & Setup (Primary)
# ──────────────────────────────────────────────────────────────────

locals {
  # Guard: cloud-init nur rendern, wenn die Datei existiert (sonst schlaegt
  # templatefile() bei deaktiviertem externen Postgres fehl).
  postgres_primary_init = fileexists("${path.module}/cloud-init-postgres-primary.sh") ? templatefile("${path.module}/cloud-init-postgres-primary.sh", {
    cluster_name     = local.cluster_name
    postgres_version = var.postgres_version
    replica_count    = var.postgres_replica_count
  }) : ""
}

# ──────────────────────────────────────────────────────────────────
# KUBERNETES SECRET: PostgreSQL Connection Strings
# ──────────────────────────────────────────────────────────────────

# Nach PostgreSQL-Setup:
# Diese Secrets werden vom Tenant-Management-Job erstellt
# Beispiel:
# - Secret: tenant-acme-postgres
#   ├─ master_url: postgresql://user:pass@10.0.1.200:5432/tenant_acme
#   ├─ replica_url: postgresql://user:pass@10.0.1.210:5432/tenant_acme
#   └─ username, password (für DB-Migrations)

# ──────────────────────────────────────────────────────────────────
# OUTPUTS
# ──────────────────────────────────────────────────────────────────

output "postgres_primary_ip" {
  description = "PostgreSQL Primary IP (Private)"
  value       = var.enable_external_postgres ? hcloud_server_network.postgres_primary[0].ip : null
}

output "postgres_replica_ips" {
  description = "PostgreSQL Replica IPs (Private)"
  value       = var.enable_external_postgres ? hcloud_server_network.postgres_replica[*].ip : []
}

output "postgres_connection_string_template" {
  description = "Template für PostgreSQL Connection String"
  value       = var.enable_external_postgres ? "postgresql://user:password@${hcloud_server_network.postgres_primary[0].ip}:5432/tenant_db" : null
}

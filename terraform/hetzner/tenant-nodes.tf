# tenant-nodes.tf – Dedizierte Worker-Nodes je Tenant (volle Trennung)
#
# Jeder Tenant aus var.tenant_nodes erhaelt einen eigenen Hetzner-Server.
# Der Server wird mit hcloud-Labels markiert; das eigentliche Kubernetes
# Node-Pinning (Label + Taint tenant.navosec.io/dedicated=<id>) setzt der
# In-Cluster-Job bzw. scripts/assign-node.sh aus dem tenant-management Modul.
#
# So bleibt die "Node-Ausrollung" je Tenant aus der Admin-Steuerung heraus
# zweistufig nachvollziehbar:
#   1. Terraform legt den dedizierten Node an (Infrastruktur).
#   2. assign-node Job/Script pinnt ihn an den Tenant (Scheduling).

resource "hcloud_server" "tenant_node" {
  for_each = var.tenant_nodes

  name         = "${local.cluster_name}-tenant-${each.key}"
  image        = var.talos_image_name
  server_type  = each.value.server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.kubernetes.id]
  automount    = false

  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    {
      "role"                       = "tenant-worker"
      "tenant.navosec.io_dedicated" = each.key
      "accelerator"                = each.value.gpu ? "nvidia-l40" : "none"
    }
  )

  depends_on = [hcloud_network_subnet.main]
}

# Attach dedizierten Tenant-Node ans Private Network
resource "hcloud_server_network" "tenant_node" {
  for_each = var.tenant_nodes

  server_id  = hcloud_server.tenant_node[each.key].id
  network_id = hcloud_network.main.id
  ip         = each.value.private_ip
}

output "tenant_node_ips" {
  description = "Private IPs der dedizierten Tenant-Nodes"
  value       = { for k, v in hcloud_server_network.tenant_node : k => v.ip }
}

output "tenant_node_names" {
  description = "Hetzner-Servernamen der dedizierten Tenant-Nodes"
  value       = { for k, v in hcloud_server.tenant_node : k => v.name }
}

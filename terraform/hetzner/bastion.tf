resource "hcloud_server" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  name              = "${local.cluster_name}-bastion"
  image             = "ubuntu-24.04"
  server_type       = var.bastion_server_type
  location          = var.location
  ssh_keys          = [hcloud_ssh_key.default.id]
  firewall_ids      = [hcloud_firewall.kubernetes.id]
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "role" = "bastion" }
  )
}

resource "hcloud_floating_ip" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  name              = "${local.cluster_name}-bastion-ip"
  type              = "ipv4"
  location          = var.location
  description       = "Bastion public IP"
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "purpose" = "bastion" }
  )
}

resource "hcloud_floating_ip_assignment" "bastion" {
  count          = var.enable_bastion ? 1 : 0
  floating_ip_id = hcloud_floating_ip.bastion[0].id
  server_id      = hcloud_server.bastion[0].id
}

resource "hcloud_server_network" "bastion" {
  count      = var.enable_bastion ? 1 : 0
  server_id  = hcloud_server.bastion[0].id
  network_id = hcloud_network.main.id
  ip         = var.bastion_private_ip
}

output "bastion_public_ip" {
  description = "Public Bastion IP"
  value       = try(hcloud_floating_ip.bastion[0].ip_address, null)
}

output "bastion_private_ip" {
  description = "Private Bastion IP"
  value       = try(hcloud_server_network.bastion[0].ip, null)
}

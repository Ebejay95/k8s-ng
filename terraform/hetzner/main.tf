# hetzner-main.tf – Hetzner Cloud Ressourcen

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  common_labels = {
    "cluster"     = local.cluster_name
    "environment" = var.environment
    "managed-by"  = "terraform"
  }
}

# ──────────────────────────────────────────────────────────────────
# NETZWERK: Private Network für K8s + PostgreSQL
# ──────────────────────────────────────────────────────────────────

resource "hcloud_network" "main" {
  name     = "${local.cluster_name}-network"
  ip_range = var.network_ip_range

  labels = local.common_labels
}

# Private Network Subnets für Nodes und PostgreSQL
resource "hcloud_network_subnet" "main" {
  network_id        = hcloud_network.main.id
  network_zone      = var.network_zone
  type              = "cloud"
  ip_range          = var.subnet_ip_range
  vswitch_id        = 0  # Default vSwitch

  depends_on = [hcloud_network.main]
}

# ──────────────────────────────────────────────────────────────────
# FLOATING IP für Load Balancer (Ingress)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_floating_ip" "ingress" {
  name              = "${local.cluster_name}-ingress-ip"
  type              = "ipv4"
  location          = var.location
  description       = "Ingress IP für ${local.cluster_name}"
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "purpose" = "ingress" }
  )
}

# ──────────────────────────────────────────────────────────────────
# SSH KEY für Node Access
# ──────────────────────────────────────────────────────────────────

resource "hcloud_ssh_key" "default" {
  name       = "${local.cluster_name}-ssh-key"
  public_key = var.ssh_public_key

  labels = local.common_labels
}

# ──────────────────────────────────────────────────────────────────
# FIREWALL für Kubernetes Cluster
# ──────────────────────────────────────────────────────────────────

resource "hcloud_firewall" "kubernetes" {
  name        = "${local.cluster_name}-fw"
  description = "Firewall für Kubernetes ${local.cluster_name}"

  labels = local.common_labels

  # Erlauben: Ingress Traffic (HTTP/HTTPS)
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  # SSH (nur für Debugging/emergencies via Bastion)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.bastion_ssh_cidrs # Nur von Bastion oder Admin
  }

  # Kubelet API (von innen)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "10250"
    source_ips = [var.subnet_ip_range] # Nur aus private network
  }

  # CoreDNS (UDP/TCP)
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "53"
    source_ips = [var.subnet_ip_range]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "53"
    source_ips = [var.subnet_ip_range]
  }

  # Talos API (für Control Plane)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = concat(var.bastion_ssh_cidrs, [var.subnet_ip_range])
  }

  # Allow all outbound
  rule {
    direction = "out"
    protocol  = "tcp"
    port      = "1-65535"
    destination_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  rule {
    direction = "out"
    protocol  = "udp"
    port      = "1-65535"
    destination_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }
}

# ──────────────────────────────────────────────────────────────────
# CONTROL PLANE NODES (Talos Linux)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_server" "control_plane" {
  count              = var.control_plane_count
  name               = "${local.cluster_name}-cp-${count.index + 1}"
  image              = var.talos_image_name  # z.B. "talos-linux-amd64" (benötigt custom image)
  server_type        = var.control_plane_type  # z.B. "cpx31" (8 vCPU, 32 GB RAM)
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.kubernetes.id]
  delete_protection  = var.environment == "prod" ? true : false
  automount          = false  # Wir mounten manual über Network Attachment

  labels = merge(
    local.common_labels,
    { "role" = "control-plane", "index" = count.index }
  )

  depends_on = [hcloud_network_subnet.main]
}

# Attach Control Plane zu Private Network
resource "hcloud_server_network" "control_plane" {
  count     = var.control_plane_count
  server_id = hcloud_server.control_plane[count.index].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.${10 + count.index}"  # 10.0.1.10, 10.0.1.11, 10.0.1.12
}

# ──────────────────────────────────────────────────────────────────
# WORKER NODES (Talos Linux)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_server" "worker" {
  count              = var.worker_node_count
  name               = "${local.cluster_name}-worker-${count.index + 1}"
  image              = var.talos_image_name
  server_type        = var.worker_node_type  # z.B. "cx51" (4 vCPU, 16 GB RAM)
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.kubernetes.id]
  automount          = false

  labels = merge(
    local.common_labels,
    { "role" = "worker", "index" = count.index }
  )

  depends_on = [hcloud_network_subnet.main]
}

# Attach Worker zu Private Network
resource "hcloud_server_network" "worker" {
  count     = var.worker_node_count
  server_id = hcloud_server.worker[count.index].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.${50 + count.index}"  # 10.0.1.50, 10.0.1.51, ...
}

# ──────────────────────────────────────────────────────────────────
# OPTIONAL: GPU NODES für Ollama/AI (teuer, optional)
# ──────────────────────────────────────────────────────────────────

resource "hcloud_server" "gpu_node" {
  count              = var.enable_gpu_nodes ? 1 : 0
  name               = "${local.cluster_name}-gpu-1"
  image              = var.talos_image_name
  server_type        = var.gpu_node_type  # z.B. "gpu_l40_1x" (NVIDIA L40 GPU)
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.default.id]
  firewall_ids       = [hcloud_firewall.kubernetes.id]
  automount          = false

  labels = merge(
    local.common_labels,
    { "role" = "gpu", "accelerator" = "nvidia-l40" }
  )

  depends_on = [hcloud_network_subnet.main]
}

# Attach GPU Node zu Private Network
resource "hcloud_server_network" "gpu_node" {
  count     = var.enable_gpu_nodes ? 1 : 0
  server_id = hcloud_server.gpu_node[0].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.100"
}

# ──────────────────────────────────────────────────────────────────
# OUTPUTS
# ──────────────────────────────────────────────────────────────────

output "floating_ip" {
  description = "Floating IP für Ingress"
  value       = hcloud_floating_ip.ingress.ip_address
}

output "control_plane_ips_private" {
  description = "Control Plane Private IPs"
  value       = hcloud_server_network.control_plane[*].ip
}

output "worker_ips_private" {
  description = "Worker Private IPs"
  value       = hcloud_server_network.worker[*].ip
}

output "network_id" {
  description = "Hetzner Private Network ID"
  value       = hcloud_network.main.id
}

output "firewall_id" {
  description = "Hetzner Firewall ID"
  value       = hcloud_firewall.kubernetes.id
}

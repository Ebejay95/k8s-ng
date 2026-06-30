# hetzner-variables.tf – Hetzner-spezifische Variablen

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Projekt-Name"
  type        = string
  default     = "navosec"
}

variable "environment" {
  description = "Umgebung (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ──────────────────────────────────────────────────────────────────
# LOCATION & REGION (Hetzner-spezifisch)
# ──────────────────────────────────────────────────────────────────

variable "location" {
  description = "Hetzner Location (fsn1, nbg1, hel1, ash)"
  type        = string
  default     = "nbg1"  # Nürnberg (Mitteleuropa)
  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash"], var.location)
    error_message = "Must be a valid Hetzner location."
  }
}

variable "network_zone" {
  description = "Network Zone (eu-central, us-west, ap-southeast)"
  type        = string
  default     = "eu-central"
}

variable "network_ip_range" {
  description = "Private Network CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_ip_range" {
  description = "Subnet CIDR für K8s Nodes"
  type        = string
  default     = "10.0.1.0/24"
}

# ──────────────────────────────────────────────────────────────────
# CONTROL PLANE NODES
# ──────────────────────────────────────────────────────────────────

variable "control_plane_count" {
  description = "Anzahl Control Plane Nodes (HA: 3 oder 5)"
  type        = number
  default     = 3
  validation {
    condition     = var.control_plane_count % 2 == 1 && var.control_plane_count >= 1
    error_message = "Must be odd number (1, 3, 5, 7, ...)"
  }
}

variable "control_plane_type" {
  description = "Hetzner Server Type für Control Plane"
  type        = string
  default     = "cpx31"  # 8 vCPU, 32 GB RAM (~€25/Monat)
}

# ──────────────────────────────────────────────────────────────────
# WORKER NODES
# ──────────────────────────────────────────────────────────────────

variable "worker_node_count" {
  description = "Anzahl Worker Nodes (Minimum 2 für HA)"
  type        = number
  default     = 2
}

variable "worker_node_type" {
  description = "Hetzner Server Type für Worker"
  type        = string
  default     = "cx51"  # 4 vCPU, 16 GB RAM (~€13/Monat)
}

# ──────────────────────────────────────────────────────────────────
# GPU NODES (optional für Ollama/AI)
# ──────────────────────────────────────────────────────────────────

variable "enable_gpu_nodes" {
  description = "GPU Nodes aktivieren?"
  type        = bool
  default     = false
}

variable "gpu_node_type" {
  description = "Hetzner GPU Server Type"
  type        = string
  default     = "gpu_l40_1x"  # NVIDIA L40 (~€500/Monat, nur wenn nötig)
}

# ──────────────────────────────────────────────────────────────────
# DEDIZIERTE TENANT NODES (volle Trennung je Kunde)
# ──────────────────────────────────────────────────────────────────

variable "tenant_nodes" {
  description = <<-EOT
    Dedizierte Worker-Nodes je Tenant. Jeder Eintrag rollt einen eigenen
    Hetzner-Server aus, der ausschliesslich fuer den Tenant verwendet wird
    (Node-Pinning via Label + Taint tenant.navosec.io/dedicated=<id>).
    Beispiel:
      tenant_nodes = {
        acme = { server_type = "cx51", gpu = false, private_ip = "10.0.1.150" }
        bigcorp = { server_type = "gpu_l40_1x", gpu = true, private_ip = "10.0.1.151" }
      }
  EOT
  type = map(object({
    server_type = string
    gpu         = optional(bool, false)
    private_ip  = string
  }))
  default = {}
}


# ──────────────────────────────────────────────────────────────────
# TALOS OS IMAGE
# ──────────────────────────────────────────────────────────────────

variable "talos_image_name" {
  description = "Name des Talos Linux Images in Hetzner"
  type        = string
  default     = "talos-linux-amd64"  # Muss manuell zu Hetzner hochgeladen sein
}

# ──────────────────────────────────────────────────────────────────
# SSH & SECURITY
# ──────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "Public SSH Key für Node Access"
  type        = string
}

variable "bastion_ssh_cidrs" {
  description = "CIDR Blocks mit SSH-Zugriff (Bastion oder Admin)"
  type        = list(string)
  default     = []  # Sollte auf deine IP gesetzt werden
}

variable "enable_bastion" {
  description = "Bastion Host aktivieren"
  type        = bool
  default     = true
}

variable "bastion_server_type" {
  description = "Hetzner Server Type fuer Bastion"
  type        = string
  default     = "cx22"
}

variable "bastion_private_ip" {
  description = "Private IP der Bastion im Cluster-Netz"
  type        = string
  default     = "10.0.1.5"
}

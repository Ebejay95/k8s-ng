# variables.tf – Terraform Input-Variablen (Cloud-Agnostisch)

variable "project_name" {
  description = "Projekt-Name (verwendet überall als Prefix)"
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

variable "region" {
  description = "Region/Zone (cloud-spezifisch wird später interpretiert)"
  type        = string
  default     = "eu-west-1"  # AWS: eu-west-1, Azure: westeurope, GCP: europe-west1
}

variable "cloud_provider" {
  description = "Cloud-Provider (aws, azure, gcp, onprem)"
  type        = string
  validation {
    condition     = contains(["aws", "azure", "gcp", "onprem"], var.cloud_provider)
    error_message = "Must be aws, azure, gcp, or onprem."
  }
}

# ──────────────────────────────────────────────────────────────────
# NETZWERK
# ──────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR Block (z.B. 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR Blocks für AZs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "enable_nat_gateway" {
  description = "NAT Gateway für Outbound Traffic aktivieren?"
  type        = bool
  default     = true
}

variable "enable_dns" {
  description = "DNS im VPC aktivieren?"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────
# KUBERNETES CLUSTER
# ──────────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "Kubernetes Version"
  type        = string
  default     = "1.28"
}

variable "cluster_endpoint_public_access" {
  description = "Kubernetes API öffentlich erreichbar?"
  type        = bool
  default     = false  # Best Practice: Private + Bastion
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR Blocks mit öffentlichem API-Zugriff (falls public_access=true)"
  type        = list(string)
  default     = []  # Sollte auf Bastion/Office IP beschränkt sein
}

# ──────────────────────────────────────────────────────────────────
# NODE POOLS
# ──────────────────────────────────────────────────────────────────

variable "default_node_pool" {
  description = "Default Node Pool Konfiguration"
  type = object({
    name           = string
    machine_type   = string  # AWS: t3.xlarge, Azure: Standard_D4s_v3
    min_size       = number
    max_size       = number
    disk_size_gb   = number
    disk_type      = string  # gp3, Premium_LRS
    node_labels    = map(string)
    node_taints    = list(string)
  })
  default = {
    name           = "default"
    machine_type   = "t3.2xlarge"  # ~8 vCPU, 32 GB RAM
    min_size       = 2
    max_size       = 10
    disk_size_gb   = 100
    disk_type      = "gp3"
    node_labels    = { "workload" = "general" }
    node_taints    = []
  }
}

variable "gpu_node_pool" {
  description = "GPU Node Pool für AI/ML Workloads (optional)"
  type = object({
    enabled        = bool
    name           = string
    machine_type   = string  # AWS: g4dn.xlarge (1x NVIDIA T4), p4d (8x A100)
    min_size       = number
    max_size       = number
    gpu_count      = number
    disk_size_gb   = number
    node_labels    = map(string)
    node_taints    = list(string)
  })
  default = {
    enabled        = true
    name           = "gpu"
    machine_type   = "g4dn.xlarge"  # AWS: 1x T4 GPU
    min_size       = 0              # Scale to 0 when not needed
    max_size       = 5
    gpu_count      = 1
    disk_size_gb   = 150
    node_labels    = { "workload" = "gpu", "accelerator" = "nvidia-t4" }
    node_taints    = [{ key = "gpu", value = "true", effect = "NoSchedule" }]
  }
}

variable "observability_node_pool" {
  description = "Observability Node Pool für Monitoring/Logging (optional)"
  type = object({
    enabled        = bool
    name           = string
    machine_type   = string
    min_size       = number
    max_size       = number
    disk_size_gb   = number
    node_labels    = map(string)
    node_taints    = list(string)
  })
  default = {
    enabled        = false  # Optional: kann auf Default laufen
    name           = "observability"
    machine_type   = "t3.xlarge"
    min_size       = 1
    max_size       = 3
    disk_size_gb   = 200    # Für Prometheus/Mimir/Grafana
    node_labels    = { "workload" = "observability" }
    node_taints    = [{ key = "observability", value = "true", effect = "NoSchedule" }]
  }
}

# ──────────────────────────────────────────────────────────────────
# NODE OS
# ──────────────────────────────────────────────────────────────────

variable "node_os" {
  description = "Node Operating System (talos, flatcar, bottlerocket)"
  type        = string
  default     = "talos"
  validation {
    condition     = contains(["talos", "flatcar", "bottlerocket"], var.node_os)
    error_message = "Must be talos, flatcar, or bottlerocket."
  }
}

variable "node_os_version" {
  description = "Node OS Version"
  type        = string
  default     = "v1.6.0"  # Talos/Flatcar Version
}

# ──────────────────────────────────────────────────────────────────
# STORAGE
# ──────────────────────────────────────────────────────────────────

variable "enable_ebs_csi" {
  description = "EBS/Block Storage CSI Driver aktivieren?"
  type        = bool
  default     = true
}

variable "enable_s3_csi" {
  description = "S3/Object Storage CSI Driver aktivieren?"
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "S3 Bucket für Object Storage (falls aktiviert)"
  type        = string
  default     = ""  # Wird auto-generiert wenn leer
}

variable "enable_rds_postgres" {
  description = "Managed RDS PostgreSQL aktivieren? (Alternativ: In-Cluster PostgreSQL)"
  type        = bool
  default     = true  # Best Practice für Production
}

variable "postgres_instance_class" {
  description = "RDS Instance Class (z.B. db.t3.medium, db.c5.large)"
  type        = string
  default     = "db.t3.medium"
}

variable "postgres_allocated_storage" {
  description = "RDS Storage Size in GB"
  type        = number
  default     = 100
}

variable "postgres_backup_retention_days" {
  description = "RDS Backup Retention (Tage)"
  type        = number
  default     = 30
}

variable "postgres_multi_az" {
  description = "RDS Multi-AZ Deployment für HA?"
  type        = bool
  default     = true  # Production: true, Dev: false
}

# ──────────────────────────────────────────────────────────────────
# DNS
# ──────────────────────────────────────────────────────────────────

variable "dns_zone_name" {
  description = "DNS Zone (z.B. meinedomain.de)"
  type        = string
}

variable "create_dns_zone" {
  description = "DNS Zone erstellen? (oder externe Zone nutzen)"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────
# LOAD BALANCER & INGRESS
# ──────────────────────────────────────────────────────────────────

variable "load_balancer_type" {
  description = "Load Balancer Typ (nlb, alb, azure_lb)"
  type        = string
  default     = "nlb"  # Network Load Balancer für Kubernetes
}

variable "enable_acme_tls" {
  description = "ACME (Let's Encrypt) TLS aktivieren?"
  type        = bool
  default     = true
}

variable "acme_email" {
  description = "E-Mail für ACME (Let's Encrypt) Registrierung"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────
# IAM & RBAC (OIDC Provider)
# ──────────────────────────────────────────────────────────────────

variable "enable_irsa" {
  description = "IAM Roles for Service Accounts aktivieren?"
  type        = bool
  default     = true  # Nur für AWS; für Azure/GCP äquivalent
}

variable "oidc_provider_enabled" {
  description = "OIDC Provider für K8s Service Accounts aktivieren?"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────
# SECURITY
# ──────────────────────────────────────────────────────────────────

variable "enable_cluster_autoscaling" {
  description = "Cluster Autoscaling aktivieren?"
  type        = bool
  default     = true
}

variable "enable_network_policy" {
  description = "Network Policies auf CNI-Ebene aktivieren?"
  type        = bool
  default     = true
}

variable "cni_plugin" {
  description = "CNI Plugin (aws-vpc, calico, cilium, azure-cni)"
  type        = string
  default     = "calico"  # Cloud-agnostisch
  validation {
    condition     = contains(["aws-vpc", "calico", "cilium", "azure-cni"], var.cni_plugin)
    error_message = "Must be aws-vpc, calico, cilium, or azure-cni."
  }
}

variable "enable_pod_security_policy" {
  description = "Pod Security Policy aktivieren? (Deprecated; verwende PSA)"
  type        = bool
  default     = false
}

variable "enable_encryption_at_rest" {
  description = "etcd Encryption at Rest aktivieren?"
  type        = bool
  default     = true
}

variable "enable_audit_logging" {
  description = "Kubernetes API Audit Logging aktivieren?"
  type        = bool
  default     = true
}

# ──────────────────────────────────────────────────────────────────
# BASTION / JUMPHOST
# ──────────────────────────────────────────────────────────────────

variable "enable_bastion" {
  description = "Bastion Host für K8s API Zugang aktivieren?"
  type        = bool
  default     = true  # Für Private Cluster notwendig
}

variable "bastion_machine_type" {
  description = "Bastion Machine Type"
  type        = string
  default     = "t3.micro"
}

variable "bastion_allowed_ssh_cidrs" {
  description = "CIDR Blocks mit SSH-Zugriff auf Bastion"
  type        = list(string)
  default     = []  # Sollte auf deine Office IP gesetzt werden
}

# ──────────────────────────────────────────────────────────────────
# TAGGING & LABELING
# ──────────────────────────────────────────────────────────────────

variable "common_tags" {
  description = "Common Tags für alle Ressourcen"
  type        = map(string)
  default = {
    "Project"     = "navosec"
    "ManagedBy"   = "terraform"
    "Component"   = "kubernetes"
  }
}

variable "additional_tags" {
  description = "Zusätzliche Tags"
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────
# BACKUP & DISASTER RECOVERY
# ──────────────────────────────────────────────────────────────────

variable "enable_backups" {
  description = "Automated Backups aktivieren (etcd, PV, RDS)?"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Backup Retention (Tage)"
  type        = number
  default     = 30
}

variable "backup_schedule" {
  description = "Backup Schedule (Cron format)"
  type        = string
  default     = "0 2 * * *"  # Täglich 2 Uhr
}

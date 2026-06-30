# providers.tf – Cloud-Provider Setup (Modular)

terraform {
  required_version = ">= 1.6"
  required_providers {
    # AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Azure
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # Google Cloud
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # Kubernetes (für Post-Cluster Setup)
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    # Helm (für Chart Deployments)
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }

  # Remote State (empfohlen für Production)
  # Uncomment und anpassen für deinen Setup:
  # backend "s3" {
  #   bucket         = "navosec-terraform-state"
  #   key            = "prod/terraform.tfstate"
  #   region         = "eu-west-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

# ──────────────────────────────────────────────────────────────────
# PROVIDER: AWS
# ──────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      var.common_tags,
      var.additional_tags,
      {
        "CreatedAt" = timestamp()
      }
    )
  }

  # Nur laden wenn cloud_provider = "aws"
  # (Verhindert Credentials-Fehler auf anderen Clouds)
}

# ──────────────────────────────────────────────────────────────────
# PROVIDER: AZURE
# ──────────────────────────────────────────────────────────────────

provider "azurerm" {
  features {}

  skip_provider_registration = false

  # Nur laden wenn cloud_provider = "azure"
}

# ──────────────────────────────────────────────────────────────────
# PROVIDER: GOOGLE CLOUD
# ──────────────────────────────────────────────────────────────────

provider "google" {
  region = var.region

  # Nur laden wenn cloud_provider = "gcp"
}

# ──────────────────────────────────────────────────────────────────
# PROVIDER: KUBERNETES
# ──────────────────────────────────────────────────────────────────

# Wird später dynamisch konfiguriert basierend auf Cluster-Output
# Siehe outputs.tf für kubeconfig_path

provider "kubernetes" {
  # Config wird nach Cluster-Creation gesetzt
  # Fallback: können manuell via kubeconfig gesetzt werden
  # config_path = var.kubeconfig_path
}

# ──────────────────────────────────────────────────────────────────
# PROVIDER: HELM
# ──────────────────────────────────────────────────────────────────

provider "helm" {
  kubernetes {
    # Config wird nach Cluster-Creation gesetzt
  }
}

# ──────────────────────────────────────────────────────────────────
# LOCAL VALUES (Cloud-Agnostische Naming)
# ──────────────────────────────────────────────────────────────────

locals {
  # Standard-Naming für alle Ressourcen
  cluster_name = "${var.project_name}-${var.environment}"
  
  # Cloud-Provider Pfade
  cloud_config = {
    aws = {
      region     = var.region  # z.B. eu-west-1
      zone_count = 3           # typisch 3 AZs
    }
    azure = {
      location   = var.region  # z.B. westeurope
      zone_count = 3
    }
    gcp = {
      region     = var.region  # z.B. europe-west1
      zone_count = 3
    }
    onprem = {
      location   = "onprem"
      zone_count = 1
    }
  }

  # Welcher Cloud-Provider ist aktiv?
  active_cloud = var.cloud_provider

  # Alle Tags zusammenfassen
  all_tags = merge(
    var.common_tags,
    var.additional_tags,
    {
      "Environment" = var.environment
      "Cluster"     = local.cluster_name
      "CloudProvider" = var.cloud_provider
    }
  )
}

# ──────────────────────────────────────────────────────────────────
# DATA SOURCES (für Cloud-spezifische Daten)
# ──────────────────────────────────────────────────────────────────

# AWS: Verfügbare Availability Zones
data "aws_availability_zones" "available" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  state  = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

# Azure: Resource Group
data "azurerm_resource_group" "main" {
  count = var.cloud_provider == "azure" ? 1 : 0
  name  = "${var.project_name}-${var.environment}-rg"
}

# GCP: Projekt-ID
data "google_client_config" "default" {
  count = var.cloud_provider == "gcp" ? 1 : 0
}

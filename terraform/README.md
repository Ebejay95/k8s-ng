# Terraform: Cloud-Agnostische Infrastruktur

## Überblick

Diese Terraform-Konfiguration erstellt eine vollständige Kubernetes-Infrastruktur für Multi-Tenant Deployments. Sie soll **cloud-agnostisch** sein, d.h. mit minimalen Anpassungen auf AWS, Azure, Google Cloud oder On-Premise lauffähig.

## Architektur

```
Terraform
  ├── Provider (AWS / Azure / Google Cloud)
  ├── Network (VPC, Subnets, Security Groups)
  ├── Compute (Nodes mit Talos/Flatcar)
  ├── Kubernetes Cluster
  ├── Node Pools (Default, GPU, Observability)
  ├── Storage (EBS/Disk, S3-like)
  ├── DNS
  └── Secrets Management (optional Vault)
```

## Dateien

- `variables.tf` – Input-Variablen (cloud-agnostisch)
- `providers.tf` – Cloud-Provider Setup (modular)
- `network.tf` – VPC, Subnets, Routing
- `compute.tf` – Nodes (Talos/Flatcar Image)
- `kubernetes.tf` – K8s Cluster + Node Pools
- `storage.tf` – PVC + CSI Drivers
- `outputs.tf` – Outputs für nächste Ebene
- `terraform.tfvars.example` – Beispiel-Werte

## Usage

```bash
# 1. Provider wählen (AWS, Azure, GCP)
export CLOUD_PROVIDER=aws  # oder azure, gcp

# 2. Variables setzen
cp terraform.tfvars.example terraform.tfvars
# Bearbeite terraform.tfvars mit deinen Werten

# 3. Init
terraform init

# 4. Plan
terraform plan -out=plan.tfstate

# 5. Apply
terraform apply plan.tfstate

# 6. Kubeconfig bekommen
terraform output kubeconfig_path
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes
```

## Nächste Schritte

Nach Terraform sind die folgenden Dateien vorbereitet:

1. `../../platform/` – Argo CD, Kyverno, Ingress
2. `../../security/` – NetworkPolicies, RBAC, PSA
3. `../../app/` – Multi-Tenant App Deployment

---

Siehe auch:
- [Terraform AWS Module](./modules/aws/) (später)
- [Terraform Azure Module](./modules/azure/) (später)
- [Terraform GCP Module](./modules/gcp/) (später)

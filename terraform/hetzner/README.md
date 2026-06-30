# Hetzner Cloud Setup für Talos Kubernetes

Hetzner Cloud ist eine kostengünstige Alternative zu AWS/Azure, besonders für europäische Workloads. Diese Konfiguration verwendet:

- **Hetzner Cloud API** für Infrastructure
- **Talos Linux** für gehärtete Kubernetes Nodes
- **Managed PostgreSQL** (wenn verfügbar) oder **Self-Hosted PostgreSQL** pro Tenant

## Dateien

- `main.tf` – Hetzner Cloud Ressourcen (VPC, Netzwerk, LB)
- `talos.tf` – Talos OS Nodes mit Cloud-Init
- `postgresql.tf` – PostgreSQL Cluster (selbst gehostet oder managed)
- `variables.tf` – Hetzner-spezifische Variablen
- `terraform.tfvars` – Hetzner Konfiguration für Production

## Architektur

```
Hetzner Cloud
├─ Virtual Private Cloud (VPC)
├─ 3x Nodes (Talos Linux, t2.large oder größer)
├─ Load Balancer (Floating IP + Service LB)
├─ Private Network (für DB-Cluster)
├─ PostgreSQL Cluster (3 Nodes, HA mit Patroni)
│  ├─ Primary DB
│  ├─ Replica 1
│  └─ Replica 2
└─ Backup Storage (Hetzner Cloud Snapshots oder S3)
```

## Features

✅ Talos Linux (gehärtet, minimal)
✅ Kubernetes 1.28+
✅ PostgreSQL Cluster (per Tenant)
✅ TLS mit Letsencrypt (via Cert-Manager später)
✅ Private Netzwerk für DB-Kommunikation
✅ Floating IP für Load Balancer
✅ Snapshots für Backup

## Kosten (Beispiel)

- 3x Nodes (t2.large, 4 vCPU, 8GB): ~€30/Monat
- Load Balancer: ~€4/Monat
- PostgreSQL Masters (separate Nodes): ~€100-200/Monat (je Tenant)
- Bandwidth: ~€5/TB

**Total: ~€150-250/Monat für Basis (ohne Tenant-DBs)**

## Nächste Schritte

1. Hetzner Cloud API Token erstellen (Console)
2. `terraform.tfvars` mit deinen Werten füllen
3. `terraform init && terraform plan`
4. `terraform apply`
5. Talos Kubeconfig abrufen
6. kubectl mit Cluster connecten
7. Deploy Argo CD, Kyverno, etc.

---

## Links

- [Hetzner Cloud API Docs](https://docs.hetzner.cloud/)
- [Talos Linux Docs](https://www.talos.dev/)
- [Patroni für PostgreSQL HA](https://github.com/zalando/patroni)

# k8s-ng: Next Generation Kubernetes Platform

> **Status:** Implementierte Basis + Overlays (test/staging/prod)
> **Target:** Shared Cluster mit harter Mandantentrennung, GitOps, Security-First, Cloud-Agnostik

---

## Zielbild

```
┌─────────────────────────────────────────────────────────────────┐
│ CLOUD-AGNOSTIK INFRASTRUKTUR (Terraform)                       │
│ ├─ VPC / Network                                               │
│ ├─ Nodes (Talos/Flatcar/Bottlerocket)                          │
│ ├─ Load Balancer                                               │
│ ├─ Storage (Block, Object)                                     │
│ ├─ DNS                                                         │
│ └─ Secrets Management (optional: Vault)                        │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ KUBERNETES CLUSTER (per Umgebung: dev, staging, prod)          │
│ ├─ Talos/Flatcar gehärtete Nodes                               │
│ ├─ Node Pools:                                                 │
│ │  ├─ Default (Web, API, General Workload)                     │
│ │  ├─ GPU/AI (Ollama, Model Serving)                           │
│ │  └─ Observability (Prometheus, Mimir, Minio)                │
│ └─ Namespaces: navosec-prod, system, observability             │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ PLATTFORM-LAYER (Kustomize + Argo CD)                          │
│ ├─ Argo CD (GitOps Orchestration)                              │
│ ├─ Kyverno (Policy Engine)                                     │
│ ├─ Trivy (Image Scanning)                                      │
│ ├─ ACS / StackRox (Runtime Security)                           │
│ ├─ Traefik Ingress (mit TLS, WebSocket)                        │
│ ├─ External Secrets (Vaultwarden Integration)                  │
│ ├─ Minio (S3-kompatibel Object Storage)                        │
│ └─ Bastion / Jumphost (für externe Zugriffe)                   │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ OBSERVABILITY-LAYER (außerhalb des primären Clusters)          │
│ ├─ Prometheus (Metriken-Collect)                              │
│ ├─ Mimir (Long-term Storage)                                   │
│ ├─ Alertmanager (externe Receiver)                             │
│ ├─ Grafana (Dashboards)                                        │
│ └─ Loki (Log Aggregation, optional)                            │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ SECURITY & POLICY LAYER                                        │
│ ├─ Pod Security Admission (restricted)                        │
│ ├─ NetworkPolicies (namespace, ingress-egress)                 │
│ ├─ RBAC (minimal privileges per workload)                      │
│ ├─ CIS Benchmark (via Kyverno)                                 │
│ ├─ Secrets Encryption (at rest + in transit)                  │
│ └─ Audit Logging (all API calls)                               │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ APPLICATION LAYER (Kubernetes Deployments)                     │
│ ├─ navosec-app Deployment (2-10 replicas, HPA)                │
│ ├─ PostgreSQL (Shared DB, Option A → Option B)                 │
│ ├─ Redis (SignalR Backplane)                                   │
│ ├─ Ollama + MinIO (AI Workloads, GPU Pool)                     │
│ └─ Health Checks, Init Containers, CronJobs                    │
└─────────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ MANDANTEN (Multi-Tenancy in der App)                           │
│ ├─ Tenant A (tenant-acme.meinedomain.de)                       │
│ │  ├─ Database: Shared (Option A) oder Dediziert (Option B)    │
│ │  ├─ Config: AuthMethods, FeatureFlags, Branding             │
│ │  ├─ Users: Lokal oder Federation (Azure AD, Okta, ...)      │
│ │  └─ Policies: RBAC, Node Affinity (optional)                │
│ │                                                              │
│ ├─ Tenant B (tenant-bigcorp.meinedomain.de)                    │
│ │  └─ (wie A)                                                  │
│ │                                                              │
│ └─ ... (weitere Mandanten)                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Struktur (k8s-ng/)

```
k8s-ng/
├── README.md
├── kustomization.yaml                     ← Root (zeigt auf base/)
├── base/
│   └── kustomization.yaml                 ← gemeinsame Basis
├── environments/
│   ├── test/
│   ├── staging/
│   └── prod/
├── docs/
│   ├── 01-MULTITENANCY-AND-IAM.md        ← Konzept Multi-Tenancy
│   ├── 02-GOOGLE-OAUTH2-AND-IAM.md
│   ├── 03-TENANT-MANAGEMENT-AUTOMATION.md
│   ├── 04-APP-INTEGRATION.md
│   ├── 05-SECURITY-BASELINE.md
│   ├── 06-ARGO-CD-GITOPS.md
│   ├── 07-OBSERVABILITY-EXTERNAL.md
│   ├── 08-BACKUP-AND-DISASTER-RECOVERY.md
│   ├── 09-CI-CD-PIPELINE.md
│   ├── 10-BASTION-HOST.md
│   ├── 11-OLLAMA-AI-WORKLOADS.md
│   ├── 12-HEALTH-CHECKS-AND-MONITORING.md
│   ├── 13-VAULTWARDEN-SECRETS.md
│   └── 14-TENANT-ISOLATION-MODES.md
│
├── security/
├── external-secrets/
├── app/
├── ollama/
├── tenant-management/
├── observability/
├── backup/
├── argocd/
└── terraform/
    ├── providers.tf
    ├── variables.tf
    ├── terraform.tfvars.example
    └── hetzner/
        ├── main.tf
        ├── variables.tf
        ├── postgresql.tf
        └── bastion.tf
```

---

## Die drei Schichten dieser Architektur

### 1️⃣ Terraform: Cloud + Basis-Infrastruktur

- **Was:** VPC, Nodes (Talos/Flatcar), Storage, DNS, Load Balancer
- **Ziel:** Cloud-agnostisch (AWS, Azure, Google Cloud, On-Premise)
- **Ansatz:** IaC mit Terraform, versioniert in Git
- **Output:** Cluster Kubeconfig, Node Pool IDs, Storage IDs

### 2️⃣ Kubernetes: Plattform + Security

- **Was:** Argo CD, Kyverno, Traefik, External Secrets, Observability
- **Ziel:** GitOps-basierte Deployment, Policy Enforcement, Security Hardening
- **Ansatz:** Kustomize (Base + Overlays), optional via Argo CD
- **Enforcement:** NetworkPolicies, RBAC, PSA, CIS Benchmark

### 3️⃣ App: Multi-Tenant Workload

- **Was:** navosec-app Deployment, PostgreSQL, Redis, AI-Jobs
- **Ziel:** Tenant-fähig, harte Isolation, skalierbar
- **Ansatz:** Kustomize + Tenant-Konfiguration (Namespaces, Policies, ExternalSecrets)
- **Isolation:** Namespaces (per Env), NetworkPolicies, RBAC, DB-Filter

---

## Phasen-Planung (Legacy)

Dieser Block ist als historische Roadmap zu verstehen. Der aktuelle operative Einstieg ist der Abschnitt
"YAML-Setup fuer Dummies" weiter unten.

### Phase 1: Fundament (Wochen 1-4)
- [ ] Terraform für Cloud + Cluster-Basis
- [ ] Talos/Flatcar Images für gehärtete Nodes
- [ ] Argo CD Installation
- [ ] Git-Repo als Source of Truth

### Phase 2: Security (Wochen 5-8)
- [ ] Pod Security Admission (PSA)
- [ ] NetworkPolicies (Deny-All, Whitelist)
- [ ] RBAC + Service Accounts
- [ ] Kyverno Policies (CIS Benchmark)
- [ ] Trivy Image Scanning in CI

### Phase 3: Multi-Tenancy (Wochen 9-12)
- [ ] App: Tenant Detection Middleware
- [ ] App: TenantId-Filter in Repositories
- [ ] Kubernetes: Tenant-Config in Kustomize Base/Overlays
- [ ] Database: Tenant-Tabellen + RLS

### Phase 4: Observability (Wochen 13-16)
- [ ] Prometheus outside Cluster
- [ ] Mimir Long-Term Storage
- [ ] Alertmanager External Receiver
- [ ] Grafana Dashboards
- [ ] Loki (optional) für Logs

### Phase 5: Erweiterte Features (Wochen 17+)
- [ ] Google OAuth2-Hardening + tenant-spezifische OIDC/SAML Federation
- [ ] ACS/StackRox Runtime Security
- [ ] Bastion Nodes
- [ ] Backup & Disaster Recovery
- [ ] Per-Tenant Node Pools (Premium)
- [ ] AI Workload Isolation (GPU Nodes)

---

## Wichtige Unterschiede zu altem k8s/

| Aspekt | Alter k8s/ | Neuer k8s-ng/ |
|--------|-----------|--------------|
| **IaC** | Nur K8s YAML | Terraform + Helm + Kustomize |
| **Cloud** | Festgelegt auf eine Cloud | Agnostisch (Cloud-Provider-Modular) |
| **Deployment** | Manuelle `kubectl apply` | Argo CD GitOps |
| **Multi-Tenancy** | Keine | Tenant-Awareness in App + K8s |
| **Security** | Basis-Health-Checks | PSA, NetworkPolicies, RBAC, CIS |
| **Observability** | In-Cluster Seq + Otel | Extern (Prometheus/Mimir) + In-Cluster |
| **Node OS** | Default Distro | Talos / Flatcar / Bottlerocket |
| **Policy** | Keine | Kyverno + CIS Hardening |
| **GitOps** | Nein | Ja (Argo CD) |

---

## Nächste Schritte

1. **Lies** [docs/01-MULTITENANCY-AND-IAM.md](docs/01-MULTITENANCY-AND-IAM.md) für Multi-Tenancy Konzept
2. **Schreib** Code für Tenant Detection Middleware (src/Api)
3. **Starten** mit Terraform für Cloud-Infrastruktur
4. **Dann** Argo CD Setup
5. **Dann** Security-Baseline (PSA, NetworkPolicies)

---

## Tools & Versionen

| Tool | Version | Grund |
|------|---------|-------|
| Terraform | 1.6+ | IaC Standard |
| Kubernetes | 1.28+ | Modern K8s Features |
| Helm | 3.12+ | Package Manager |
| Argo CD | 2.8+ | GitOps |
| Kyverno | 1.10+ | Policy Engine |
| Talos / Flatcar | Latest | Security-Hardened OS |
| Trivy | 0.45+ | Image Scanning |
| ACS / StackRox | 4.0+ | Runtime Security |

---

## Quick Links

- [Multi-Tenancy & IAM Architektur](docs/01-MULTITENANCY-AND-IAM.md)
- [Google OAuth2 & IAM](docs/02-GOOGLE-OAUTH2-AND-IAM.md)
- [Tenant Management Automation](docs/03-TENANT-MANAGEMENT-AUTOMATION.md)
- [Security Baseline](docs/05-SECURITY-BASELINE.md)
- [Argo CD GitOps](docs/06-ARGO-CD-GITOPS.md)
- [Vaultwarden Secrets Setup](docs/13-VAULTWARDEN-SECRETS.md)

---

## YAML-Setup fuer Dummies (jetzt direkt nutzbar)

Ich habe aus den MDs eine klare YAML-Struktur gebaut, damit du nicht mehr alles aus Texten manuell zusammensuchen musst.

### 1) Was liegt wo?

- `security/`: Namespaces, Pod Security, RBAC, NetworkPolicies, Kyverno-Basispolicy
- `app/`: Deployment, Service, Ingress, HPA, ConfigMap, Secret-Template
- `ollama/`: GPU/AI Workload (Deployment, Service, PVC) im Namespace `ai`
- `tenant-management/`: Tenant-Manager RBAC + Job-Templates (Create/Delete/Backup)
- `observability/`: Prometheus Agent (scrape + remote_write)
- `backup/`: PostgreSQL Backup CronJob + Velero Schedule Beispiel
- `argocd/`: AppProjects + Beispiel-Applications
- `terraform/hetzner/bastion.tf`: Bastion Host IaC (statt separatem K8s-Ordner)
- `../.github/workflows/`: CI/CD Workflows (staging/prod)
- `kustomization.yaml`: Root-Datei, die alles zusammenfasst

### 2) Wie deploye ich das?

```bash
cd k8s-ng
kubectl apply -k .
```

Environment-spezifisch:

```bash
# test
kubectl apply -k environments/test

# staging
kubectl apply -k environments/staging

# prod
kubectl apply -k environments/prod
```

### 3) Was musst du vorher anpassen?

- In `external-secrets/10-bitwarden-cli-credentials-template.yaml` alle `CHANGE_ME` Werte setzen
- In `app/21-externalsecret-navosec-app.yaml` die Vaultwarden Item-ID(s) setzen
- In `app/50-ingress.yaml` Domain anpassen (`meinedomain.de`)
- In `argocd/20-application-platform.yaml` und `argocd/30-application-app.yaml` Repo-URL setzen
- In `observability/20-configmap.yaml` `remote_write` URL auf dein externes Prometheus setzen

### 4) Wie pruefe ich, ob alles laeuft?

```bash
kubectl get ns
kubectl get pods -n navosec-prod
kubectl get pods -n observability
kubectl get networkpolicy -n navosec-prod
kubectl get hpa -n navosec-prod
```

### 5) Was habe ich dabei konkret gemacht?

- Aus den Architekturdokumenten die Kern-Bausteine in echte YAML-Ressourcen ueberfuehrt
- Die Ressourcen in fachliche Ordner getrennt (Security, App, Tenant, Monitoring, Backup, GitOps)
- Eine Root-Kustomize gebaut, damit du mit einem einzigen Deploy-Schritt starten kannst
- Health-Probes, HPA, Non-Root SecurityContext und Default-Deny-Netzwerkregeln eingebaut

### 6) Separation + Hardening + Hardware-Limits (jetzt aktiv)

- Namespace-Isolation mit Default-Deny Ingress/Egress fuer `navosec-prod`, `ai`, `observability`, `external-secrets`, `argocd`
- Explizite Freigaben nur fuer noetige Kommunikationswege (z. B. `navosec-app -> ollama`)
- `LimitRange` pro Namespace fuer Default CPU/RAM Requests/Limits
- `ResourceQuota` pro Namespace als harte Obergrenze (inkl. GPU-Quota im `ai` Namespace)
- SecurityContext-Haertung in zentralen Deployments/Jobs (`runAsNonRoot`, `allowPrivilegeEscalation: false`, `seccomp: RuntimeDefault`)

Schnell-Checks:

```bash
kubectl get networkpolicy -A
kubectl get limitrange -A
kubectl get resourcequota -A
kubectl get deploy -A -o yaml | grep -n "allowPrivilegeEscalation\|runAsNonRoot\|seccompProfile"
```

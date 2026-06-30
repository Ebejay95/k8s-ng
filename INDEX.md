# INDEX – Quick Navigation durch k8s-ng Setup

## 📖 Leseanleitung

**Du bist neu hier?** → Starte mit `COMPLETE_SETUP.md`

**Du brauchst spezifische Antworten?** → Nutze diese Übersicht:

**Du willst pro Umgebung deployen?**
- [environments/test](environments/test)
- [environments/staging](environments/staging)
- [environments/prod](environments/prod)

---

## 🎓 Konzepte verstehen

| Frage | Dokumentation |
|-------|-----------------|
| Wie funktioniert Multi-Tenancy? | [01-MULTITENANCY-AND-IAM.md](docs/01-MULTITENANCY-AND-IAM.md) |
| Wie funktioniert Google OAuth2? | [02-GOOGLE-OAUTH2-AND-IAM.md](docs/02-GOOGLE-OAUTH2-AND-IAM.md) |
| Wie werden neue Tenants erstellt? | [03-TENANT-MANAGEMENT-AUTOMATION.md](docs/03-TENANT-MANAGEMENT-AUTOMATION.md) |
| Wie integriere ich die App? | [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md) |
| Wie nutze ich Vaultwarden fuer Secrets? | [13-VAULTWARDEN-SECRETS.md](docs/13-VAULTWARDEN-SECRETS.md) |
| Wie trenne ich Tenants mit/ohne eigene Pods? | [14-TENANT-ISOLATION-MODES.md](docs/14-TENANT-ISOLATION-MODES.md) |

---

## 🏗️ Infrastruktur deployen

| Was | Datei |
|-----|-------|
| Hetzner Cluster (VPC, Nodes, Firewall) | [terraform/hetzner/main.tf](terraform/hetzner/main.tf) |
| PostgreSQL HA (Primary + Replicas) | [terraform/hetzner/postgresql.tf](terraform/hetzner/postgresql.tf) |
| Variablen definieren | [terraform/hetzner/variables.tf](terraform/hetzner/variables.tf) |
| Terraform ausrollen | `terraform plan && terraform apply` |

---

## 🔐 Sicherheit einrichten

| Komponente | Dokumentation | Manifeste |
|------------|---|---|
| Pod Security Admission | [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md) | [security/psa-restricted.yaml](security/psa-restricted.yaml) |
| NetworkPolicies (Deny-All) | [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md) | [security/network-policies-*.yaml](security/) |
| RBAC + Service Accounts | [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md) | [security/rbac-base.yaml](security/rbac-base.yaml) |
| Kyverno Policies | [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md) | [security/kyverno-policies.yaml](security/kyverno-policies.yaml) |
| Audit Logging | [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md) | [security/audit-policy.yaml](security/audit-policy.yaml) |

```bash
kubectl apply -f security/
```

---

## 🚀 GitOps + Platform

| Was | Dokumentation | Aktion |
|-----|---|---|
| Argo CD Installation | [06-ARGO-CD-GITOPS.md](docs/06-ARGO-CD-GITOPS.md) | `helm install argocd argo/argo-cd` |
| App Projects (RBAC) | [06-ARGO-CD-GITOPS.md](docs/06-ARGO-CD-GITOPS.md) | [argocd/app-projects.yaml](argocd/app-projects.yaml) |
| Applications deployen | [06-ARGO-CD-GITOPS.md](docs/06-ARGO-CD-GITOPS.md) | [argocd/apps/](argocd/apps/) |

```bash
kubectl apply -f argocd/
argocd app sync navosec-prod
```

---

## 📊 Monitoring (Extern!)

| Komponente | Dokumentation | Manifest |
|---|---|---|
| Prometheus Agent (im Cluster) | [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md) | [observability/prometheus-agent.yaml](observability/prometheus-agent.yaml) |
| Alert Rules | [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md) | [observability/alert-rules.yaml](observability/alert-rules.yaml) |
| External Prometheus Setup | [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md) | Script im Doc |
| Mimir (Long-term Storage) | [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md) | S3 Backend |
| Alertmanager (Email/Slack) | [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md) | Externe Config |

---

## 💾 Backup & Disaster Recovery

| Komponente | Dokumentation | Aktion |
|---|---|---|
| Velero (K8s State) | [08-BACKUP-AND-DISASTER-RECOVERY.md](docs/08-BACKUP-AND-DISASTER-RECOVERY.md) | [backup/velero-install.yaml](backup/velero-install.yaml) |
| PostgreSQL Backups | [08-BACKUP-AND-DISASTER-RECOVERY.md](docs/08-BACKUP-AND-DISASTER-RECOVERY.md) | [backup/postgres-backup-cronjob.yaml](backup/postgres-backup-cronjob.yaml) |
| Restore Procedures | [08-BACKUP-AND-DISASTER-RECOVERY.md](docs/08-BACKUP-AND-DISASTER-RECOVERY.md) | Scripts im Doc |

```bash
kubectl apply -f backup/
velero backup create --wait  # Test
```

---

## 🔧 CI/CD Pipeline

| Komponente | Dokumentation | Aktion |
|---|---|---|
| GitHub Actions Workflow (Staging) | [09-CI-CD-PIPELINE.md](docs/09-CI-CD-PIPELINE.md) | [.github/workflows/staging.yml](../.github/workflows/staging.yml) |
| GitHub Actions Workflow (Production) | [09-CI-CD-PIPELINE.md](docs/09-CI-CD-PIPELINE.md) | [.github/workflows/prod.yml](../.github/workflows/prod.yml) |
| Trivy Scanning | [09-CI-CD-PIPELINE.md](docs/09-CI-CD-PIPELINE.md) | Script im Doc |
| Cosign Image Signing | [09-CI-CD-PIPELINE.md](docs/09-CI-CD-PIPELINE.md) | Script im Doc |

---

## 🖥️ Administrative Access (Bastion)

| Was | Dokumentation | Aktion |
|---|---|---|
| Bastion Setup | [10-BASTION-HOST.md](docs/10-BASTION-HOST.md) | [terraform/hetzner/bastion.tf](terraform/hetzner/bastion.tf) |
| SSH Tunneling | [10-BASTION-HOST.md](docs/10-BASTION-HOST.md) | `ssh -L 6443:cp:6443 bastion` |
| Argo CD via Tunnel | [10-BASTION-HOST.md](docs/10-BASTION-HOST.md) | `ssh -L 8080:argo-cd:443 bastion` |

```bash
ssh -fNL 6443:10.0.1.10:6443 ubuntu@BASTION_IP
kubectl --server=https://localhost:6443 get pods
```

---

## 🤖 AI Workloads (Ollama + GPU)

| Komponente | Dokumentation | Manifest |
|---|---|---|
| GPU Node Pool | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | [terraform/hetzner/gpu-nodes.tf](terraform/hetzner/gpu-nodes.tf) |
| NVIDIA Device Plugin | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | Script im Doc |
| Ollama Deployment | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | [ollama/20-deployment.yaml](ollama/20-deployment.yaml) |
| Ollama Service | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | [ollama/30-service.yaml](ollama/30-service.yaml) |
| Ollama Storage | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | [ollama/10-pvc.yaml](ollama/10-pvc.yaml) |
| App Integration (C#) | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | Code Snippets im Doc |

---

## ❤️ Health Checks & Monitoring

| Probe | Dokumentation | Aktion |
|---|---|---|
| Startup Probe | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | `/health/startup` Endpoint |
| Liveness Probe | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | `/health/live` Endpoint |
| Readiness Probe | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | `/health/ready` Endpoint |
| Custom Health Checks | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | C# Code im Doc |
| Metrics Middleware | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | Prometheus Integration |

---

## 🔄 App Integration Roadmap

| Schritt | Dokumentation | Datei |
|--------|---|---|
| 1. Middleware Setup | [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md) | `src/Api/Program.cs` |
| 2. TenantDetectionMiddleware | [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md) | `src/Api/Middleware/TenantDetectionMiddleware.cs` |
| 3. BaseRepository | [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md) | `src/Shared/Repositories/BaseRepository.cs` |
| 4. DbContextFactory | [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md) | `src/Api/Infrastructure/AppDbContextFactory.cs` |
| 5. Health Checks | [12-HEALTH-CHECKS-AND-MONITORING.md](docs/12-HEALTH-CHECKS-AND-MONITORING.md) | `src/Api/Health/` |
| 6. Ollamaa Service | [11-OLLAMA-AI-WORKLOADS.md](docs/11-OLLAMA-AI-WORKLOADS.md) | `src/AiImport/Services/OllamaService.cs` |

---

## 🎯 Die wichtigsten Dateien (Must-Read)

1. **COMPLETE_SETUP.md** – Gesamtübersicht (start here!)
2. **04-APP-INTEGRATION.md** – Tenant Detection in der App
3. **terraform/hetzner/main.tf** – Cluster-Infrastruktur
4. **05-SECURITY-BASELINE.md** – Sicherheits-Setup
5. **06-ARGO-CD-GITOPS.md** – GitOps Workflow

---

## 🚀 Quick Start (5 Min)

```bash
# 1. Infrastruktur
cd terraform/hetzner
terraform init && terraform plan

# 2. Security
kubectl apply -f ../../security/

# 3. Argo CD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd

# 4. Monitoring
kubectl apply -f ../../observability/

# 5. Health Check
curl https://kunde1.meinedomain.de/health/ready
```

---

## 🆘 Häufige Fragen

**Q: Wo fange ich an?**
→ COMPLETE_SETUP.md lesen, dann Terraform ausrollen

**Q: Wie integriere ich die App?**
→ [04-APP-INTEGRATION.md](docs/04-APP-INTEGRATION.md)

**Q: Wie secure ist das Setup?**
→ [05-SECURITY-BASELINE.md](docs/05-SECURITY-BASELINE.md)

**Q: Wie überwache ich den Cluster?**
→ [07-OBSERVABILITY-EXTERNAL.md](docs/07-OBSERVABILITY-EXTERNAL.md)

**Q: Wie stelle ich Backups sicher?**
→ [08-BACKUP-AND-DISASTER-RECOVERY.md](docs/08-BACKUP-AND-DISASTER-RECOVERY.md)

**Q: Wie deploye ich CI/CD?**
→ [09-CI-CD-PIPELINE.md](docs/09-CI-CD-PIPELINE.md)

**Q: Wie hole ich Secrets aus Vaultwarden?**
→ [13-VAULTWARDEN-SECRETS.md](docs/13-VAULTWARDEN-SECRETS.md)

---

## 📞 Hilf mir!

1. Lese die relevante Dokumentation oben
2. Schaue dir die Code-Beispiele an
3. Passe deine Konfiguration an
4. Test lokal, dann Production
5. Queries? Frag einen Kollegen oder Dokumentation erneut lesen

---

**Version:** 1.0 (Juni 2025)
**Status:** Production Ready ✅
**All 12 Documentations:** Complete ✅

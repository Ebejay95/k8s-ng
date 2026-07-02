# Tenant Management: Kubernetes Manifeste & Tools

Diese Ordner enthält alle Kubernetes Ressourcen für automatisierte Tenant-Verwaltung.

## Struktur

```
tenant-management/
├── README.md (dieses File)
├── kustomization.yaml            ← deployt NUR SA + Scheduled-Restart
├── service-account.yaml          ← RBAC für Tenant Manager
├── 50-scheduled-restart-cronjob.yaml  ← A21: tägl. rollierender Neustart (<24h)
├── templates/                    ← EINZIGER Provisioning-Pfad (via Skripte)
│   ├── namespace.yaml.tpl
│   ├── networkpolicies.yaml.tpl
│   ├── limits-and-quotas.yaml.tpl
│   ├── db.yaml.tpl
│   ├── app.yaml.tpl              ← dedizierte App + Service + Ingress je Tenant
│   └── ollama-dedicated.yaml.tpl  ← verpflichtend je Tenant
└── scripts/
  ├── assign-node.sh             ← Node-Pinning (Label + Taint)
  ├── bootstrap-tenant.sh        ← Tenant anlegen (wendet templates/*.tpl an)
  └── delete-tenant.sh           ← Tenant entfernen
```

> **Hinweis:** Frühere Job-Manifeste (`10-tenant-creation-*`, `20-tenant-deletion-*`,
> `30-tenant-backup-*`, `40-tenant-node-assignment-*`) wurden entfernt. Sie
> duplizierten die `templates/*.tpl` + `scripts/*.sh` und schlugen bei direktem
> `kubectl apply` fehl. Provisioning läuft ausschließlich über die Skripte
> (bzw. die Admin-API, die dieselben Templates nutzt). Per-Tenant-Datensicherung
> übernimmt Velero (Schedule `tenants-daily`, PV-Ebene).

## Usage

### Tenant über API erstellen (empfohlen)

```bash
curl -X POST https://admin.meinedomain.de/api/admin/tenants \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ACME Corp",
    "subdomain": "acme",
    "adminEmail": "admin@acmecorp.com",
    "plan": "pro"
  }'
```

### Tenant über Kubernetes erstellen (CLI)

```bash
# 1) Node dediziert an den Tenant pinnen (Label + Taint)
./scripts/assign-node.sh acme <node-name>

# 2) Tenant voll provisionieren (App + DB + Ingress + dediziertes Ollama)
DOMAIN=meinedomain.de ./scripts/bootstrap-tenant.sh acme <bitwarden-db-item-id> <node-name>
```

### Tenant löschen

```bash
./scripts/delete-tenant.sh acme
```

## Architektur

1. **Voll dedizierter Tenant-Stack (erzwungen)**
  - eigener Node je Kunde (Label + Taint `tenant.navosec.io/dedicated=<id>`)
  - Namespace je Kunde (`tenant-<id>`)
  - eigene App + Service + Ingress (`<id>.<domain>`)
  - eigene DB + Secret je Kunde
  - eigene Quotas + NetworkPolicies je Kunde
  - **verpflichtend dediziertes Ollama** je Kunde (eigener Pod + PVC)

2. **Admin-Base (Control-Plane)**
  - eigener Namespace `navosec-admin`, eigener Host `admin.<domain>`
  - eigene DB (`navosec_admin`), haelt die zentrale Tenant-Registry
  - serviciert keine Kundendaten
  - kann Tenant- und Node-Provisionierung anstossen
    (RoleBinding `admin-app-tenant-orchestrator`)

3. **Automatisiert per Skript/Job**
  - `assign-node` pinnt einen Node an den Tenant (Label + Taint)
  - Bootstrap erstellt Namespace, Netpols, Quotas, DB-Secret, App, Ingress, Ollama

## Sicherheit

- ✅ ServiceAccount mit minimalen Permissions
- ✅ Role-based Access Control (RBAC)
- ✅ Default-Deny + Whitelist Network Policies je Tenant Namespace
- ✅ ResourceQuota + LimitRange je Tenant Namespace
- ✅ Secrets für Credentials (nicht im Job-Spec)
- ✅ Audit Logging für alle Tenant-Operationen

## Monitoring

- Überwache Job-Status via:
  ```bash
  kubectl get jobs -n navosec-prod -l job=tenant-creation
  kubectl logs job/tenant-creation-acme -n navosec-prod
  ```

- Alerting: Wenn Job fehlschlägt → Alert an Admin (via Prometheus/Alertmanager)

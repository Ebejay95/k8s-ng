# 14-TENANT-ISOLATION-MODES.md – Volle Tenant-Trennung + Admin-Base

## Kurzantwort

Volle Trennung ist jetzt der erzwungene Standard:

- **Admin-Base** als eigene App (Control-Plane) im Namespace `navosec-admin`,
  eigener Host `admin.<domain>`, eigene DB (`navosec_admin`). Serviciert KEINE
  Kundendaten, haelt nur die zentrale Tenant-Registry.
- **Jeder Kunde** bekommt eine voll dedizierte App im eigenen Namespace
  `tenant-<id>`: eigenes Deployment, eigener Service, eigener Ingress
  (`<id>.<domain>`), eigene DB + Secret, eigene NetworkPolicies, Quotas, Limits,
  **eigener Node** (Node-Pinning) und **verpflichtend eigenes Ollama**.
- Es gibt **keine geteilte Multi-Tenant-App** mehr (das alte `app/` wurde entfernt).
- Es gibt **kein geteiltes Ollama** mehr – jeder Tenant betreibt eine eigene
  Ollama-Instanz in seinem Namespace auf seinem dedizierten Node.

## Ebenen

```
Control-Plane (Admin-Base)        Tenant-Plane (je Kunde)
  namespace: navosec-admin          namespace: tenant-<id>
  app: navosec-admin                app: navosec-app + ollama
  host: admin.<domain>              host: <id>.<domain>
  db:  navosec_admin                db:  je Kunde (eigene DB)
  node: shared/control              node: dediziert (Label+Taint)
```

## Node-Isolation je Tenant

Jeder Tenant-Node traegt:

- Label: `tenant.navosec.io/dedicated=<id>`
- Taint: `tenant.navosec.io/dedicated=<id>:NoSchedule`

Die Tenant-Pods (App + Ollama) tragen ein passendes `nodeSelector` + eine
`toleration`, sodass sie ausschliesslich auf dem dedizierten Node schedulen
und kein fremder Workload auf diesen Node gelangt.

Node-Ausrollung (zweistufig, admin-steuerbar):

1. **Infrastruktur:** `terraform/hetzner/tenant-nodes.tf` legt je Tenant einen
   eigenen Hetzner-Server an (`var.tenant_nodes`).
2. **Scheduling:** `scripts/assign-node.sh` bzw. der Job
   `40-tenant-node-assignment-job-template.yaml` pinnt den Node an den Tenant
   (Label + Taint). Beides kann aus der Admin-App ueber die Kubernetes-API
   ausgeloest werden (RoleBinding `admin-app-tenant-orchestrator`).

## AI: verpflichtend dediziertes Ollama

- Jeder Tenant bekommt zwingend eine eigene Ollama-Instanz + PVC im eigenen
  Namespace, gepinnt auf den dedizierten Tenant-Node.
- Benoetigt GPU-Kapazitaet auf dem Tenant-Node (`gpu = true` in
  `var.tenant_nodes` bzw. GPU-Servertyp).

---

## Was ist jetzt im Repo vorhanden?

- Admin-Base (Control-Plane) als eigene App:
  - `admin/` (Namespace, ConfigMap, ExternalSecret, Deployment, Service,
    Ingress, HPA, NetworkPolicies, Limits/Quotas)

- Templates fuer voll dedizierte Tenant-Stacks:
  - `tenant-management/templates/namespace.yaml.tpl`
  - `tenant-management/templates/networkpolicies.yaml.tpl`
  - `tenant-management/templates/limits-and-quotas.yaml.tpl`
  - `tenant-management/templates/db-externalsecret.yaml.tpl`
  - `tenant-management/templates/app.yaml.tpl` (App + Service + Ingress je Tenant)
  - `tenant-management/templates/ollama-dedicated.yaml.tpl` (verpflichtend)

- Job-Templates (admin-/API-steuerbar):
  - `tenant-management/10-tenant-creation-job-template.yaml`
  - `tenant-management/40-tenant-node-assignment-job-template.yaml`

- Infrastruktur:
  - `terraform/hetzner/tenant-nodes.tf` (dedizierte Nodes je Tenant)

- Automationsskripte:
  - `tenant-management/scripts/bootstrap-tenant.sh`
  - `tenant-management/scripts/assign-node.sh`
  - `tenant-management/scripts/delete-tenant.sh`

---

## Beispiele

### 1) Node ausrollen + Tenant provisionieren (CLI)

```bash
cd k8s-ng/tenant-management

# a) dedizierten Node an den Tenant pinnen (Label + Taint)
./scripts/assign-node.sh acme navosec-prod-tenant-acme

# b) Tenant voll provisionieren (App + DB + Ingress + dediziertes Ollama)
DOMAIN=meinedomain.de ./scripts/bootstrap-tenant.sh acme <bitwarden-db-item-id> navosec-prod-tenant-acme
```

Ergebnis:
- Node `...-tenant-acme` ist dediziert fuer `acme`
- Namespace `tenant-acme`
- voll dedizierte App + Service + Ingress (`acme.meinedomain.de`)
- DB-Secret-Sync je Kunde
- verpflichtend dediziertes Ollama + PVC
- harte Policies/Quotas

### 2) Steuerung aus der Admin-App (Ziel)

Die Admin-App erstellt ueber die Kubernetes-API Instanzen von
`40-tenant-node-assignment-job-template.yaml` und
`10-tenant-creation-job-template.yaml` (Variablen `TENANT_ID`, `NODE_NAME`,
`PLAN`, `DOMAIN`). Die Berechtigung dafuer liefert das RoleBinding
`admin-app-tenant-orchestrator` (ServiceAccount `navosec-admin`).

---

## Empfehlung

- Admin-Base laeuft permanent als Control-Plane (`admin.<domain>`).
- Jeder Kunde laeuft voll getrennt: eigener Node, eigene App, eigene DB,
  eigenes Ollama.
- Node-Kapazitaet/GPU je Tenant ueber `var.tenant_nodes` steuern.

# 03-TENANT-MANAGEMENT-AUTOMATION.md – Automatisierte Tenant-Operationen via Kubernetes Jobs

## Überblick

Mit separaten Datenbanken pro Tenant (oder Kundengruppe) brauchen wir automatisierte Jobs für:

1. **Tenant-Erstellung**: Neue DB, User, Schema, Secrets, Ingress, Storage
2. **Tenant-Löschung**: Backup, DB-Cleanup, Secret-Löschung, Ingress-Entfernung
3. **Tenant-Scaling**: HPA-Anpassung basierend auf Metrics
4. **Tenant-Backup**: Nightly Backups pro Tenant
5. **Tenant-Restore**: Recovery von Snapshots
6. **Tenant-Onboarding**: Initiale Konfiguration (Users, Features, Branding)

Diese werden als **Kubernetes CronJobs** implementiert, getriggert durch **API-Calls** oder **Webhooks** von der Admin-Oberfläche.

---

## Architektur

```
Admin Panel (Google OAuth2)
    │
    ├─ POST /admin/tenants (Create)
    │   └─ → Tenant Creation Job (K8s Job)
    │       ├─ PostgreSQL DB erstellen
    │       ├─ Secret mit Connection String
    │       ├─ Ingress Regel hinzufügen
    │       ├─ Storage Volume erstellen
    │       └─ Update Tenant Registry
    │
    ├─ DELETE /admin/tenants/{id} (Delete)
    │   └─ → Tenant Deletion Job (K8s Job)
    │       ├─ Backup erstellen
    │       ├─ DB löschen
    │       ├─ Secret löschen
    │       ├─ Ingress löschen
    │       └─ Storage bereinigen
    │
    ├─ PATCH /admin/tenants/{id}/scale (Scale)
    │   └─ → Tenant Scaling Job (K8s Job)
    │       ├─ HPA Min/Max anpassen
    │       ├─ Resource Requests anpassen
    │       └─ Monitoring Alert Limits anpassen
    │
    └─ POST /admin/backup/tenant/{id} (Backup)
        └─ → Tenant Backup Job (K8s Job)
            ├─ DB Dump
            ├─ Upload zu Backup Storage
            └─ Snapshot metadata speichern

CronJob: Nightly Backup
    └─ Für alle Tenants: pg_dump → S3 (Minio)

CronJob: Nightly Restore Test
    └─ Testet ob Backups wiederherstellbar sind (optional)

CronJob: Cleanup
    └─ Löscht alte Backups (> 30 Tage)
```

---

## Tenant Management API (in der App)

Die Admin-Oberfläche ruft diese Endpoints auf:

```csharp
// Controllers/AdminTenantController.cs

[ApiController]
[Route("api/admin/tenants")]
[Authorize(Roles = "admin,support-tier2")]
public class AdminTenantController : ControllerBase
{
    // 1. Tenant erstellen
    [HttpPost]
    public async Task<IActionResult> CreateTenant([FromBody] CreateTenantRequest request)
    {
        var job = new TenantCreationJob
        {
            TenantName = request.Name,
            Subdomain = request.Subdomain,
            AdminEmail = request.AdminEmail,
            Plan = request.Plan,  // free, pro, enterprise
        };

        // Job in K8s Job Warte-Queue stellen
        await _tenantManagementService.QueueTenantCreationAsync(job);

        return Accepted(new { job_id = job.Id });
    }

    // 2. Tenant löschen
    [HttpDelete("{tenantId}")]
    public async Task<IActionResult> DeleteTenant(string tenantId, [FromQuery] bool backup = true)
    {
        var job = new TenantDeletionJob
        {
            TenantId = tenantId,
            CreateBackup = backup,
        };

        await _tenantManagementService.QueueTenantDeletionAsync(job);

        return Accepted(new { job_id = job.Id });
    }

    // 3. Tenant skalieren
    [HttpPatch("{tenantId}/scale")]
    public async Task<IActionResult> ScaleTenant(string tenantId, [FromBody] ScaleTenantRequest request)
    {
        var job = new TenantScalingJob
        {
            TenantId = tenantId,
            MinReplicas = request.MinReplicas,
            MaxReplicas = request.MaxReplicas,
            CpuRequest = request.CpuRequest,
            MemoryRequest = request.MemoryRequest,
        };

        await _tenantManagementService.QueueTenantScalingAsync(job);

        return Accepted(new { job_id = job.Id });
    }
}
```

---

## Kubernetes Job: Tenant-Erstellung

```yaml
# k8s-ng/tenant-management/tenant-creation-job.yaml

apiVersion: batch/v1
kind: Job
metadata:
  name: tenant-creation-{{ tenant_id }}
  namespace: navosec-prod
  labels:
    job: tenant-creation
    tenant: "{{ tenant_id }}"
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 3600  # 1h max
  template:
    spec:
      serviceAccountName: tenant-manager
      restartPolicy: Never

      containers:
        - name: tenant-creator
          image: navosec-tools:tenant-creation-latest
          imagePullPolicy: IfNotPresent

          env:
            # Tenant-Details
            - name: TENANT_ID
              value: "{{ tenant_id }}"
            - name: TENANT_NAME
              value: "{{ tenant_name }}"
            - name: SUBDOMAIN
              value: "{{ subdomain }}"
            - name: ADMIN_EMAIL
              value: "{{ admin_email }}"
            - name: PLAN
              value: "{{ plan }}"  # free, pro, enterprise

            # PostgreSQL Credentials (für DB Admin)
            - name: POSTGRES_ADMIN_HOST
              value: "10.0.1.200"
            - name: POSTGRES_ADMIN_PORT
              value: "5432"
            - name: POSTGRES_ADMIN_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-admin-secret
                  key: username
            - name: POSTGRES_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-admin-secret
                  key: password

            # Kubernetes Config
            - name: KUBERNETES_SERVICE_HOST
              value: "kubernetes.default.svc.cluster.local"
            - name: KUBERNETES_SERVICE_PORT
              value: "443"

          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"

---

# Kubernetes-spezifisch: ServiceAccount für Tenant Manager
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-manager
  namespace: navosec-prod

---

# Role: Was der Tenant Manager tun darf
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-manager
  namespace: navosec-prod
rules:
  # Secrets erstellen/lesen/löschen
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "list", "delete", "update"]

  # Ingress-Regeln hinzufügen
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["create", "get", "list", "delete", "update", "patch"]

  # PVC für Tenant Storage
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["create", "get", "list", "delete"]

  # ConfigMaps für Tenant-Settings
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create", "get", "list", "delete", "update", "patch"]

  # HPA für Tenant Auto-Scaling
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["create", "get", "list", "delete", "update", "patch"]

---

apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-manager
  namespace: navosec-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant-manager
subjects:
  - kind: ServiceAccount
    name: tenant-manager
    namespace: navosec-prod
```

---

## Tenant-Erstellung: Was der Job macht

```bash
#!/bin/bash
# tenant-creation-entrypoint.sh

set -euo pipefail

echo "🚀 Starting Tenant Creation Job"
echo "  Tenant ID: $TENANT_ID"
echo "  Subdomain: $SUBDOMAIN"

# ──────────────────────────────────────────────────────────────────
# Schritt 1: PostgreSQL Database erstellen
# ──────────────────────────────────────────────────────────────────

echo "1️⃣ Creating PostgreSQL database..."

DB_NAME="tenant_${TENANT_ID//[-._]/}"
DB_USER="user_${TENANT_ID:0:10}"
DB_PASSWORD=$(openssl rand -base64 32)

PGHOST=$POSTGRES_ADMIN_HOST \
PGPORT=$POSTGRES_ADMIN_PORT \
PGUSER=$POSTGRES_ADMIN_USER \
PGPASSWORD=$POSTGRES_ADMIN_PASSWORD \
psql -h $POSTGRES_ADMIN_HOST -U $POSTGRES_ADMIN_USER <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
EOF

echo "✅ Database created: $DB_NAME"

# ──────────────────────────────────────────────────────────────────
# Schritt 2: Kubernetes Secret mit Credentials erstellen
# ──────────────────────────────────────────────────────────────────

echo "2️⃣ Creating Kubernetes Secret..."

kubectl create secret generic "tenant-$TENANT_ID-db" \
  --from-literal=host=$POSTGRES_ADMIN_HOST \
  --from-literal=port=$POSTGRES_ADMIN_PORT \
  --from-literal=database=$DB_NAME \
  --from-literal=username=$DB_USER \
  --from-literal=password=$DB_PASSWORD \
  --from-literal=connection_string="postgresql://${DB_USER}:${DB_PASSWORD}@${POSTGRES_ADMIN_HOST}:${POSTGRES_ADMIN_PORT}/${DB_NAME}" \
  -n navosec-prod \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secret created: tenant-$TENANT_ID-db"

# ──────────────────────────────────────────────────────────────────
# Schritt 3: Ingress-Regel hinzufügen
# ──────────────────────────────────────────────────────────────────

echo "3️⃣ Adding Ingress rule..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tenant-$TENANT_ID
  namespace: navosec-prod
  labels:
    tenant: $TENANT_ID
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "${SUBDOMAIN}.meinedomain.de"
      secretName: letsencrypt-prod
  rules:
    - host: "${SUBDOMAIN}.meinedomain.de"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: navosec-app
                port:
                  name: http
EOF

echo "✅ Ingress rule added: ${SUBDOMAIN}.meinedomain.de"

# ──────────────────────────────────────────────────────────────────
# Schritt 4: HPA (Horizontal Pod Autoscaler) für Tenant erstellen (optional)
# ──────────────────────────────────────────────────────────────────

echo "4️⃣ Creating HPA policy..."

MIN_REPLICAS=2
MAX_REPLICAS=10
if [ "$PLAN" = "pro" ]; then
  MIN_REPLICAS=3
  MAX_REPLICAS=20
elif [ "$PLAN" = "enterprise" ]; then
  MIN_REPLICAS=5
  MAX_REPLICAS=50
fi

cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: tenant-$TENANT_ID
  namespace: navosec-prod
  labels:
    tenant: $TENANT_ID
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: navosec-app
  minReplicas: $MIN_REPLICAS
  maxReplicas: $MAX_REPLICAS
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
EOF

echo "✅ HPA created: min=$MIN_REPLICAS, max=$MAX_REPLICAS"

# ──────────────────────────────────────────────────────────────────
# Schritt 5: Tenant in Datenbank registrieren
# ──────────────────────────────────────────────────────────────────

echo "5️⃣ Registering Tenant in Central DB..."

# Hier Connection zu Shared Tenants-Registry (im Cluster)
# Diese DB enthält nur Tenant-Metadaten, nicht Kunden-Daten
CENTRAL_DB_CONNECTION=$(kubectl get secret navosec-app-secret -n navosec-prod \
  -o jsonpath='{.data.connection}' | base64 -d)

PSQL_COMMAND="
INSERT INTO Tenants (Id, Subdomain, Name, DatabaseConnection, Status, CreatedAt)
VALUES (
  '$TENANT_ID',
  '$SUBDOMAIN',
  '$TENANT_NAME',
  'postgresql://${DB_USER}:${DB_PASSWORD}@${POSTGRES_ADMIN_HOST}:${POSTGRES_ADMIN_PORT}/${DB_NAME}',
  'Active',
  NOW()
);"

echo $PSQL_COMMAND | PGCONNSTR=$CENTRAL_DB_CONNECTION psql

echo "✅ Tenant registered in Central DB"

# ──────────────────────────────────────────────────────────────────
# Schritt 6: Run Database Migrations (Tenant DB)
# ──────────────────────────────────────────────────────────────────

echo "6️⃣ Running Database Migrations..."

# Baue Tenant-spezifische Connection String
TENANT_CONNECTION_STRING="postgresql://${DB_USER}:${DB_PASSWORD}@${POSTGRES_ADMIN_HOST}:${POSTGRES_ADMIN_PORT}/${DB_NAME}"

# Nutze dotnet ef migrations
docker run --rm \
  -e ConnectionStrings__DefaultConnection="$TENANT_CONNECTION_STRING" \
  navosec-web:latest \
  dotnet ef database update \
  --context AppDbContext

echo "✅ Migrations completed"

# ──────────────────────────────────────────────────────────────────
# SUCCESS
# ──────────────────────────────────────────────────────────────────

echo "✨ Tenant creation complete!"
echo ""
echo "📋 Tenant Details:"
echo "  ID: $TENANT_ID"
echo "  Subdomain: $SUBDOMAIN"
echo "  URL: https://${SUBDOMAIN}.meinedomain.de"
echo "  Database: $DB_NAME"
echo "  Admin Email: $ADMIN_EMAIL"
echo ""
echo "Next: Admin erhält Onboarding-Email"
```

---

## Nächste Schritte

1. **Tenant Creation Job** fertigstellen (oben)
2. **Tenant Deletion Job** bauen (mit Backup)
3. **Tenant Scaling Job** bauen
4. **Nightly Backup CronJob** bauen
5. **Monitoring & Alerting** für Job-Fehler
6. **API in Admin-Panel** integrieren (CreateTenant, DeleteTenant, ScaleTenant)
7. **Webhook** für GitOps? (bei neuer Tenant Auto-Deploy)

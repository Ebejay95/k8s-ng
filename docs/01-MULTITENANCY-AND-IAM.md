# Multi-Tenancy & IAM Architektur

## Überblick

Dieses Dokument beschreibt die Zielarchitektur für:
1. **Shared Cluster mit harter Mandantentrennung**
2. **Multi-Tenancy in der Anwendung**
3. **Zentrales internes IAM + externe Kunden-SSO**
4. **Request-Flow von Kunde bis zur Datenbank**

---

## 1. Architektur-Ebenen

```
┌────────────────────────────────────────────────────────────────┐
│ INTERNET                                                       │
│ kunde1.meinedomain.de  │  kunde2.meinedomain.de  │  admin...   │
└────────────────────────────────────────────────────────────────┘
              ▼                    ▼                    ▼
┌────────────────────────────────────────────────────────────────┐
│ KUBERNETES INGRESS (Traefik)                                   │
│ DNS Resolution → Ingress Rules → Service Routing              │
└────────────────────────────────────────────────────────────────┘
        ▼                    ▼                         ▼
┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────┐
│ TENANT-APP (kunde1)  │ │ TENANT-APP (kunde2)  │ │ ADMIN-BASE        │
│ ns: tenant-kunde1    │ │ ns: tenant-kunde2    │ │ ns: navosec-admin │
│ host: kunde1.<dom>   │ │ host: kunde2.<dom>   │ │ host: admin.<dom> │
│ eigene Pods + DB     │ │ eigene Pods + DB     │ │ Control-Plane,    │
│ eigene NetPol/Quota  │ │ eigene NetPol/Quota  │ │ Tenant-Registry   │
└──────────────────────┘ └──────────────────────┘ └──────────────────┘
        ▼                    ▼                         ▼
┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────┐
│ DB: tenant_kunde1    │ │ DB: tenant_kunde2    │ │ DB: navosec_admin │
└──────────────────────┘ └──────────────────────┘ └──────────────────┘

Erzwungen: KEINE geteilte Multi-Tenant-App. Jeder Kunde laeuft als
voll dedizierter Stack (Namespace + App + DB + Ingress). Die Admin-Base
ist selbst eine App, serviciert aber keine Kundendaten.
```

---

## 2. Tenant-Erkennung

### Primärer Anker: Subdomain

```
kunde1.meinedomain.de  →  TenantId: tenant-001
kunde2.meinedomain.de  →  TenantId: tenant-002
admin.meinedomain.de   →  TenantId: internal (nur interne Nutzer)
```

**Implementierung in der App:**
- Middleware in `Program.cs` extrahiert aus `Host`-Header die Subdomain.
- Resolution über eine Tenant-Registry (DB-Lookup oder Cache).
- Tenant-Context wird als `IHttpContextAccessor.HttpContext.Items["Tenant"]` oder ähnlich gespeichert.
- Alle nachfolgenden Services können sicher auf `CurrentTenant` zugreifen.

**Fallback & Validierung:**
- Unbekannte Subdomains → 404 oder Redirect zu Root.
- Keine Subdomain (nur meinedomain.de) → Landing Page oder Redirect.

---

## 3. Authentifizierung (AuthN)

### 3.1 Interne Benutzer (Admin, Support, Plattform)

**IAM-Quelle:** Google OAuth2/Workspace (intern) + optional Entra ID/Authentik (zentrales Workforce-IAM)

```
Admin-Benutzerin
    │
    ▼
Zentrales IAM (z.B. Google OAuth2/Workspace)
    │ OIDC Token mit Rollen:
    │ - PlatformAdmin
    │ - SecurityAdmin
    │ - SupportTier1/2
    ▼
App erhält Token über OAuth2/OIDC
    │
    ▼
Token wird zu JWT für App-interne Verarbeitung konvertiert
```

**Rollen (Plattformebene):**
- `PlatformAdmin` – Zugriff auf alle Tenants, Admin-Oberflächen
- `SecurityAdmin` – Policies, Audit, Secrets
- `Support` – Lesezugriff auf Kunden-Tenants, begrenzte Admin-Aktionen
- `SupportTier2` – erweiterte Support-Rechte
- `Operator` – Betrieb, Monitoring-Zugriff

Diese Rollen werden **nicht** in der Multi-Tenant-App verwendet, sondern nur für interne Ebenen (Bastion, Argo CD, Headlamp, Grafana, ACS).

### 3.2 Externe Kunden-Benutzer

**AuthN-Modelle pro Tenant:**

**Modell A: Lokales Login**
```
Benutzer gibt Credentials ein
    │
    ▼
App prüft gegen eigene Password-DB (gehashed, salted)
    │
    ▼
JWT Token mit TenantId + UserId
```

**Modell B: Externer IdP (OIDC/SAML)**
```
Benutzer wird zu Kunden-IdP redirected (z.B. Kundes Okta, Azure AD)
    │
    ▼
IdP authentifiziert und sendet Token/Assertion zurück
    │
    ▼
App validiert Signature, mapped zu lokalem User (oder erstellt ihn)
    │
    ▼
JWT Token mit TenantId + UserId + externe IdP als Quelle
```

**Konfiguration pro Tenant (in DB oder Git):**
```yaml
Tenant: customer-acme
  AuthMethods:
    - Type: Local
    - Type: OIDC
      Provider: https://acme-okta.okta.com
      ClientId: <secret>
      ClientSecret: <secret>
      Mapping:
        Email: email
        DisplayName: given_name + family_name
        Groups: groups
```

### 3.3 Token-Struktur

JWT mit Tenant-Binding (verhindert Token-Crossing):

```json
{
  "sub": "user-123",
  "email": "alice@acme.com",
  "tenant_id": "tenant-acme",
  "tenant_domain": "acme.meinedomain.de",
  "roles": ["TenantAdmin", "RiskManager"],
  "iss": "https://meinedomain.de/auth",
  "aud": "navosec-app",
  "exp": 1700000000
}
```

**Wichtig:** Der Token ist an `tenant_id` gebunden. Ein Token von tenant-acme kann nicht auf tenant-bigcorp verwendet werden, auch wenn die App ihn akzeptiert.

---

## 4. Autorisierung (AuthZ)

### 4.1 Zwei-Schichten-Modell

```
Layer 1: Tenant-Zugehörigkeit
  ├─ Ist dieser Benutzer Mitglied von Tenant X?
  └─ JWT enthält tenant_id, Host-Header muss matchen

Layer 2: Tenant-lokale Rollen & Berechtigungen
  ├─ TenantAdmin       → alle Aktionen im Tenant
  ├─ RiskManager       → nur Risk-Aggregates
  ├─ Auditor           → Read-only
  └─ Custom Role X     → tenant-spezifische Rollen
```

### 4.2 Autorisierungs-Logik in der App

```csharp
// Middleware / Endpoint Handler
public async Task<IResult> GetRisks(HttpContext context, IRiskService riskService)
{
    // 1. Tenant-Kontext extrahieren
    var tenant = context.Items["Tenant"] as Tenant;
    var claims = context.User.Claims;

    // 2. Tenant-Match validieren
    var tokenTenant = claims.FirstOrDefault(c => c.Type == "tenant_id")?.Value;
    if (tokenTenant != tenant.Id)
        return Results.Forbid(); // Token ist für anderen Tenant

    // 3. Rollen-Prüfung
    if (!context.User.HasClaim(c =>
        c.Type == "roles" &&
        (c.Value == "RiskManager" || c.Value == "TenantAdmin" || c.Value == "Auditor")))
        return Results.Forbid();

    // 4. Datenzugriff mit Tenant-Filter
    var risks = await riskService.GetRisksForTenant(tenant.Id);
    return Results.Ok(risks);
}
```

---

## 5. Request-Flow: Von kunde1.meinedomain.de zur Datenbank

```
┌──────────────────────────────────────────────────────────────────────┐
│ Step 1: Client-Anfrage                                               │
│ GET https://kunde1.meinedomain.de/api/risks                          │
│ Authorization: Bearer <JWT>                                          │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 2: Ingress (Traefik)                                            │
│ • Empfängt request auf *.meinedomain.de                              │
│ • Forwarded an navosec-app Service (ClusterIP)                       │
│ • Setzt X-Forwarded-Host: kunde1.meinedomain.de                      │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 3: App Pod (Program.cs Middleware)                              │
│                                                                       │
│ a) TenantDetectionMiddleware                                         │
│    ├─ Host = X-Forwarded-Host = kunde1.meinedomain.de                │
│    ├─ Subdomain-Extraktion: "kunde1"                                 │
│    ├─ DB-Lookup: Tenant id = "tenant-001"                            │
│    └─ context.Items["Tenant"] = Tenant(id: "tenant-001", ...)        │
│                                                                       │
│ b) AuthenticationMiddleware (JWT)                                    │
│    ├─ JWT Signature validieren                                       │
│    ├─ Token-Claims extrahieren                                       │
│    ├─ context.User = ClaimsPrincipal(...)                            │
│    └─ JWT enthält: tenant_id = "tenant-001"                          │
│                                                                       │
│ c) TenantMatchValidationMiddleware (NEU)                             │
│    ├─ Tenant aus Step 3a = "tenant-001"                              │
│    ├─ Tenant aus JWT Token = "tenant-001"                            │
│    ├─ Match? JA → continue                                           │
│    └─ Match? NEIN → 403 Forbidden                                    │
│                                                                       │
│ d) AuthorizationMiddleware                                           │
│    ├─ User hat Role "RiskManager" oder "TenantAdmin"?                │
│    └─ JA → continue, NEIN → 403 Forbidden                            │
│                                                                       │
│ e) Controller / Handler wird aufgerufen                              │
│    ├─ handler weiß: CurrentTenant = "tenant-001"                     │
│    └─ handler weiß: User = alice@acme.com mit Rollen                 │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 4: Application Layer (MediatR Handler)                          │
│                                                                       │
│ Command/Query Handler empfängt:                                      │
│   ├─ CurrentTenant (aus HttpContext oder DI)                         │
│   ├─ CurrentUser (aus Claims)                                        │
│   ├─ Business-Query (z.B. "GetRisks")                                │
│                                                                       │
│ Domain Service / Use Case:                                           │
│   ├─ Validiert nochmal TenantId = "tenant-001"                       │
│   ├─ Bauen Query mit WHERE TenantId = 'tenant-001'                   │
│   └─ Ruft Repository auf                                             │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 5: Repository Layer (EF Core)                                   │
│                                                                       │
│ Protected Repository<T>:                                             │
│   ├─ IQueryable<T> ApplyTenantFilter(IQueryable<T> query)            │
│   │  └─ return query.Where(x => x.TenantId == currentTenant.Id)      │
│   │                                                                  │
│   ├─ GetAllAsync() calls ApplyTenantFilter automatisch               │
│   │                                                                  │
│   └─ Direkter DB-Zugriff ohne Filter → Exception/Audit-Log          │
│                                                                       │
│ Query Example:                                                       │
│   SELECT * FROM Risks                                                │
│   WHERE TenantId = 'tenant-001'                                      │
│   AND RiskStatus = 'Active'                                          │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 6: PostgreSQL Database                                          │
│                                                                       │
│ Execution Plan:                                                      │
│   ├─ Use index on (TenantId, RiskStatus) if available                │
│   ├─ Return rows WHERE TenantId = 'tenant-001'                       │
│   └─ No cross-tenant data leakage possible                           │
│                                                                       │
│ Database Schema (Option A: Shared DB):                               │
│   ├─ Risks table: (Id, TenantId, Name, Status, ...)                  │
│   ├─ Index: (TenantId, Status)                                       │
│   ├─ RLS Policy (PostgreSQL 10+):                                    │
│   │  ALTER TABLE Risks ENABLE ROW LEVEL SECURITY;                    │
│   │  CREATE POLICY risks_tenant_isolation                            │
│   │    ON Risks USING (TenantId = current_tenant_id());              │
│   └─ (Zusätzliche Sicherheitsebene, aber Code ist primär)            │
└──────────────────────────────────────────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Step 7: Response zurück zum Client                                   │
│                                                                       │
│ 200 OK                                                               │
│ {                                                                    │
│   "risks": [                                                         │
│     { "id": "risk-1", "name": "...", "tenantId": "tenant-001" },     │
│     { "id": "risk-2", "name": "...", "tenantId": "tenant-001" }      │
│   ]                                                                  │
│ }                                                                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 6. Tenant-Konfiguration & Datenhaltung

### 6.1 Mandantenkonfiguration (DB-gespeichert)

```sql
CREATE TABLE Tenants (
    Id UUID PRIMARY KEY,
    Subdomain VARCHAR(255) UNIQUE NOT NULL,  -- "kunde1", "kunde2"
    DisplayName VARCHAR(255) NOT NULL,
    Status VARCHAR(50) NOT NULL,  -- Active, Suspended, Deleted
    AuthMethods JSONB NOT NULL,   -- [{ Type: "Local" }, { Type: "OIDC", Provider: "..." }]
    FeatureFlags JSONB,           -- { "AIImport": true, "CustomBranding": false, ... }
    CustomBranding JSONB,         -- { "Logo": "...", "Colors": { "Primary": "#..." } }
    DatabaseConnection VARCHAR(1000),  -- optional: für Option B (dedizierte DB)
    NodePoolAffinity VARCHAR(255),     -- optional: "customer-acme-pool", "gpu-ai-pool"
    CreatedAt TIMESTAMPTZ,
    UpdatedAt TIMESTAMPTZ
);
```

### 6.2 Benutzer & Rollen (DB-gespeichert)

```sql
CREATE TABLE Users (
    Id UUID PRIMARY KEY,
    TenantId UUID NOT NULL REFERENCES Tenants(Id),
    Email VARCHAR(255) NOT NULL,
    PasswordHash VARCHAR(500),  -- NULL wenn nur externe IdP
    ExternalIdpIdentifier VARCHAR(500),  -- z.B. "okta:user@acme.com"
    DisplayName VARCHAR(255),
    Status VARCHAR(50),  -- Active, Suspended
    CreatedAt TIMESTAMPTZ,
    UpdatedAt TIMESTAMPTZ,
    UNIQUE (TenantId, Email)
);

CREATE TABLE UserRoles (
    Id UUID PRIMARY KEY,
    UserId UUID NOT NULL REFERENCES Users(Id),
    TenantId UUID NOT NULL REFERENCES Tenants(Id),
    RoleId VARCHAR(100) NOT NULL,  -- "TenantAdmin", "RiskManager", ...
    CreatedAt TIMESTAMPTZ,
    UNIQUE (UserId, RoleId)
);
```

### 6.3 Tenant-Datenmodell: Option A vs Option B

**Option A: Shared Database (Start)**
```
Alle Tenants in einer PostgreSQL-Instanz
  ├─ Single Schema
  ├─ TenantId in jeder Tabelle
  ├─ Row-Level Security (PostgreSQL) zusätzliche Sicherheit
  ├─ Günstiger (eine DB)
  ├─ Einfacher Backup (ein DB-Backup)
  └─ Späterer Umzug auf Option B möglich
```

**Option B: Separate Database (Premium/später)**
```
Pro Tenant oder Kundengruppe eine eigene PostgreSQL-Instanz
  ├─ Separate Schemas oder separate DBs
  ├─ Kein TenantId-Filter nötig (Isolation durch separate DB)
  ├─ Teurer (mehrere DB-Instanzen)
  ├─ Komplexeres Backup (mehrere DBs)
  ├─ Stärkere Isolation (z.B. für Compliance)
  └─ Späteres Scaling: Premium-Kunden auf dedizierte DB
```

**Hybrid-Ansatz (empfohlen):**
```
Standard-Kunden in Shared DB (Option A)
Premium-Kunden bekommen Option B später
  ├─ Code baut Connection-String basierend auf Tenant
  ├─ Tenant hat optional ConnectionString-Override
  ├─ StandardValue = central Shared DB
  ├─ Premium kann Override setzen auf eigene DB
  └─ App wechselt DbContext-Ziel entsprechend
```

---

## 7. Sicherheits-Garantien

### 7.1 Auf Anwendungs-Ebene

- ✅ Tenant-Kontext an Host-Header gebunden
- ✅ JWT enthält Tenant-Claim
- ✅ Jede Anfrage validiert Tenant-Match
- ✅ Repositories filtern automatisch nach TenantId
- ✅ Keine unbefilterten Queries möglich
- ✅ Rollen-basierte Autorisierung pro Tenant

### 7.2 Auf Kubernetes-Ebene

- ✅ NetworkPolicies: nur Pods in Namespace dürfen sich unterhalten
- ✅ Service Accounts: dediziert pro Workload
- ✅ RBAC: nur nötige Rechte pro Service
- ✅ Pod Security Admission (PSA) restricted
- ✅ Secret Management: Secrets sind Kubernetes Secrets, nicht im Code
- ✅ Optional: dedizierte Node-Pools pro Tenant (später)

### 7.3 Auf Datenbank-Ebene (Zusatzebene)

- ✅ PostgreSQL Row-Level Security (RLS)
  ```sql
  CREATE POLICY tenant_isolation ON Risks
    USING (TenantId = current_setting('app.current_tenant_id')::UUID);
  ```
- ✅ Index auf TenantId für Performance
- ✅ Backups sind tenant-aware (später: pro-Tenant Restores)

---

## 8. Falsche Sicherheit (was NICHT ausreicht)

- ❌ **Nur HTTP-Header-Filter** – können vom Client manipuliert werden
- ❌ **Rollen ohne Tenant-Kontext** – Admin ohne Tenant ist zu mächtig
- ❌ **Request-Scope ohne erzwingenden Filter** – vergessener Filter in Repository
- ❌ **Token ohne Tenant-Binding** – Token kann zwischen Tenants kopiert werden
- ❌ **Keine Validierung bei Datenbank-Operation** – Bypass möglich über direkten DB-Zugang
- ❌ **Kubernetes-Isolation ohne App-Logik** – zwei feindliche Tenants im gleichen Pod

---

## 9. Interne Benutzer & Admin-Zugriff

### 9.1 Support-Szenario

Support-Mitarbeiter muss einen Bug in Kundenconto beheben:

```
1. Support-Mitarbeiter loggt sich auf admin.meinedomain.de ein
  ├─ Zentrales IAM (Google OAuth2/Entra)
   ├─ Token enthält Rolle: "Support"
   └─ Tenant = "internal"

2. App hat /admin/impersonate Endpoint (mit SupportTier2-Check)
   ├─ Support kann einen Kunden-Tenant auswählen
   ├─ Session wird auf "tenant-acme" geswitched
   ├─ Audit-Log: "Support impersonated tenant-acme at 2025-06-30 10:30:00"

3. Support kann jetzt im Kunden-Kontext arbeiten
   ├─ Darf nur lesend arbeiten oder vordefinierte Admin-Aktionen
   ├─ Alles ist auditiert (Audit-Table mit Admin-Kontext, Timestamp, Action)

4. Session-Timeout nach 1h, Impersonate-Mode wird beendet
```

### 9.2 Sicherheitsebene

- ✅ Impersonate-Rechte sind strict (nur Support & höher)
- ✅ Ist zeitlich begrenzt (1h Session)
- ✅ Wird vollständig auditiert
- ✅ Alert auf Monitoring (Support nutzt Impersonate → Security-Team benachrichtigen)

---

## 10. Externe IdP Anbindung (OIDC/SAML)

### 10.1 Ablauf: Kunde will Azure AD SSO

```
1. Admin von Tenant-Acme registriert sich auf admin.acme.meinedomain.de
   ├─ Lokal als TenantAdmin (lokales Login)
   └─ Kann SSO konfigurieren

2. Admin konfiguriert Azure AD:
   ├─ Admin App: Azure AD → App Registrations → New
   ├─ Redirect URI: https://acme.meinedomain.de/auth/oidc-callback
   ├─ Client ID & Secret kopiert → Admin Panel eingeben

3. Konfig wird in DB gespeichert (encrypted):
   ├─ Tenants.AuthMethods = [
   │    { Type: "Local" },
   │    { Type: "OIDC", Provider: "https://login.microsoftonline.com/.../oauth2/v2.0",
   │      ClientId: "...", ClientSecret: "encrypted..." }
   │  ]

4. Benutzer von Acme navigiert zu acme.meinedomain.de
   ├─ Login-Form zeigt zwei Buttons:
   │  - "Login mit E-Mail & Passwort (Lokal)"
   │  - "Login mit Microsoft Azure AD"

5. Benutzer clickt "Azure AD"
   ├─ App redirected zu https://login.microsoftonline.com/...
   ├─ User authentifiziert sich mit Acme-AD
   ├─ Azure AD redirected zurück mit Code

6. App tauscht Code gegen Token (Backend)
   ├─ Token ist signiert von Azure AD
   ├─ App validiert Signatur mit Azure AD Public Key (cached)
   ├─ Token enthält Claims (email, name, groups, ...)

7. App created oder updated lokalen User
   ├─ Lookup: User mit email=alice@acme.com + ExternalIdpIdentifier=azure:alice@acme.com
   ├─ Nicht gefunden? Create new User (mit optionaler Admin-Genehmigung)
   ├─ Bereits da? Update DisplayName, Status, etc. aus Azure Token

8. App issued JWT Token (intern)
   ├─ JWT enthält sub=user-123, tenant_id=tenant-acme
   └─ Browser speichert in LocalStorage

9. Benutzer kann jetzt auf acme.meinedomain.de arbeiten
```

### 10.2 Groups/Roles Mapping

```
Azure AD Groups → App Rollen (optional):

Tenant-Admin konfiguriert:
  Azure AD Group: "acme-risk-managers"
    →  App Role: "RiskManager"

  Azure AD Group: "acme-admins"
    →  App Role: "TenantAdmin"

Beim Login:
  JWT enthält groups = ["acme-risk-managers", "acme-admins"]

  App sucht Mapping:
    "acme-risk-managers" → setze Rolle "RiskManager"
    "acme-admins" → setze Rolle "TenantAdmin"

  User wird angelegt/updated mit diesen Rollen
```

---

## 11. Kubernetes Multi-Tenancy Ergänzung

Während die App die fachliche Multi-Tenancy handhabt, unterstützt Kubernetes die Isolation:

```yaml
# Ein Namespace pro Environment, nicht pro Tenant
# (Tenants teilen sich Namespace in Shared Cluster)

kind: Namespace
metadata:
  name: navosec-prod
  labels:
    env: production

---

# Service Account für die App
kind: ServiceAccount
metadata:
  name: navosec-app
  namespace: navosec-prod

---

# Role: minimale Berechtigungen
kind: Role
metadata:
  name: navosec-app
  namespace: navosec-prod
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["navosec-app-secret", "postgres-secret", "redis-secret"]

---

# RoleBinding: Service Account → Role
kind: RoleBinding
metadata:
  name: navosec-app
  namespace: navosec-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: navosec-app
subjects:
  - kind: ServiceAccount
    name: navosec-app
    namespace: navosec-prod

---

# NetworkPolicy: nur ingress-controller → pod
kind: NetworkPolicy
metadata:
  name: navosec-app
  namespace: navosec-prod
spec:
  podSelector:
    matchLabels:
      app: navosec-app
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: traefik-system
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector: {}  # allow cluster DNS
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

---

## 12. Rollen-Hierarchie (Referenz)

### Plattform-Rollen (intern, für Operatoren)
Nicht für Multi-Tenant-App, sondern für Argo CD, Headlamp, Monitoring, etc.

```
PlatformAdmin
├─ Super-Admin: alles sehen, alles ändern
├─ Zugriff: Argo CD (alle Apps), Headlamp (alle Namespaces), Grafana (global)

SecurityAdmin
├─ Policies, Audit, Incident Response
├─ Zugriff: ACS/StackRox, Audit-Logs, Security-Dashboard

SupportTier1
├─ First-line support, kann Kunden-Tenants read-only inspizieren
├─ Zugriff: Headlamp (beschränkt), Grafana (Kunden-Dashboards)

SupportTier2
├─ Impersonate, begrenzte Admin-Aktionen
├─ Zugriff: Admin Impersonate, Audit-Logs, Support Dashboard

Operator
├─ Infrastruktur-Überwachung
├─ Zugriff: Grafana Cluster-Metriken, Log-Aggregation
```

### Tenant-lokale Rollen (pro Mandant)
```
TenantAdmin
├─ Alles im Tenant (User, Rollen, Settings, Data)

RiskManager
├─ Nur Risk-Aggregate (erstellen, editieren, löschen)

Auditor
├─ Read-only alles im Tenant

Custom Role
├─ Tenant kann eigene Rollen definieren
└─ (optional, später)
```

---

## 13. Nächste Schritte

Diese Architektur wird umgesetzt in:

1. **App-Seite (src/Api):**
   - [ ] TenantDetectionMiddleware
   - [ ] TenantMatchValidationMiddleware
   - [ ] Tenant + User Claim Resolution
   - [ ] Protected Base Repository mit TenantId-Filter
   - [ ] Admin Impersonate Endpoint
   - [ ] External IdP (OIDC) Support

2. **Kubernetes-Seite (k8s-ng):**
  - [ ] Kustomize Base/Overlay mit Tenant-Config
   - [ ] NetworkPolicies
   - [ ] RBAC & Service Accounts
   - [ ] Secret Management
   - [ ] Optional: Tenant-spezifische Node Affinity

3. **Security-Seite (k8s-ng/security):**
   - [ ] Kyverno Policies (Multi-Tenancy Enforcement)
   - [ ] Pod Security Admission
   - [ ] CIS Hardening

4. **Plattform-Seite (k8s-ng):**
  - [ ] Google OAuth2 / zentrales IAM Setup
   - [ ] Argo CD Integration mit intern RBAC
   - [ ] Headlamp mit Plattform-Rollen
   - [ ] ACS/StackRox Policies pro Tenant

---

## Zusammenfassung

**Multi-Tenancy heißt:**
- Eine App-Instanz, viele Kunden.
- Tenant wird über Host-Header erkannt.
- JWT muss Tenant enthalten und matchen.
- Rollen sind tenant-lokal.
- Jede DB-Query wird automatisch nach TenantId gefiltert.

**IAM heißt:**
- Intern: Workforce-IAM (Google OAuth2/Entra) mit Plattform-Rollen.
- Extern: Pro Tenant lokales Login + optional externe IdP (OIDC/SAML).
- Admins können Tenants mit Audit-Trail impersonieren.

**Sicherheit heißt:**
- Mehrere Validierungs-Ebenen (Host, JWT-Claim, Rolle, DB-Filter).
- Keine single point of failure.
- Alles auditiert und alertbar.

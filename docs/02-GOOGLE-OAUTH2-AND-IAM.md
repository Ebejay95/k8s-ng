# 02-GOOGLE-OAUTH2-AND-IAM.md – Google OAuth2 für interne Benutzer + Interne Plattform-Rollen

## Überblick

Anstelle von Keycloak nutzen wir **Google OAuth2** für interne Benutzer (Team, Admins, Support). Das ist:

- ✅ Kostenlos (Google Workspace ist sowieso vorhanden)
- ✅ MFA bereits integriert (Google 2FA, Security Keys)
- ✅ Keine zusätzliche IAM-Infrastruktur zu betreiben
- ✅ Audit-Logs via Google Admin Console

**Wichtig:** Google OAuth2 ist nur für **Interne Benutzer** (eure Firma). Für **Kunden-Benutzer** bleibt das separate OAuth2-Modell pro Tenant (lokales Login + optional externe IdP).

---

## Architektur: Zwei IAM-Systeme

```
┌─────────────────────────────────────────────────────────────────┐
│ INTERNE BENUTZER (Plattform-Betreiber)                          │
│                                                                 │
│ Google Workspace Konto (@euereFirma.de)                         │
│ → Google OAuth2 Login                                           │
│ → Token mit Google-Claim bekommt Plattform-Rollen              │
│   ├─ PlatformAdmin                                              │
│   ├─ SecurityAdmin                                              │
│   ├─ SupportTier1/2                                             │
│   └─ Operator                                                   │
│                                                                 │
│ Zugriff auf: Argo CD, Headlamp, Grafana, ACS, Bastion           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ EXTERNE BENUTZER (Kunden)                                       │
│                                                                 │
│ Pro Tenant:                                                     │
│ Option A: Lokales Login (E-Mail + Passwort)                     │
│ Option B: Externe IdP (Azure AD, Okta, Google, ...)             │
│           (konfigurierbar pro Tenant)                           │
│                                                                 │
│ Zugriff auf: kunde1.meinedomain.de, kunde2.meinedomain.de       │
│ Rollen: Tenant-Admin, RiskManager, Auditor, ...                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Google OAuth2 Setup

### Schritt 1: Google Cloud Project erstellen

1. Gehe zu [Google Cloud Console](https://console.cloud.google.com/)
2. Erstelle neues Projekt: `navosec-platform`
3. Aktiviere die **OAuth Consent Screen**:
   - Type: Internal (nur Workspace-Benutzer)
   - App Name: Navosec Platform
   - Scopes: `email`, `profile`, `openid`

### Schritt 2: OAuth2 Credentials erstellen

1. **Create Credentials** → **OAuth Client ID** → **Web application**
2. Authorized redirect URIs:
   ```
   https://admin.meinedomain.de/auth/google/callback
   https://localhost:3000/auth/google/callback  (lokal)
   ```
3. Speichere **Client ID** und **Client Secret**

### Schritt 3: Google Workspace Group erstellen (Optional aber empfohlen)

Erstelle Google Groups für Rollen:
- `navosec-platform-admins@euereFirma.de` → PlatformAdmin
- `navosec-security-admins@euereFirma.de` → SecurityAdmin
- `navosec-support@euereFirma.de` → Support

Dadurch kannst du Rollen via Gruppen-Zugehörigkeit vergeben, statt hartcodiert.

---

## App-Seitige Implementierung (C#)

### 1. Program.cs – Google OAuth2 konfigurieren

```csharp
// Program.cs (Api)

var builder = WebApplication.CreateBuilder(args);

// ──────────────────────────────────────────────────────────────
// AUTHENTICATION: Google OAuth2
// ──────────────────────────────────────────────────────────────

var googleAuth = builder.Configuration.GetSection("GoogleAuth");

builder.Services
    .AddAuthentication(options =>
    {
        options.DefaultScheme = "Cookies";
        options.DefaultChallengeScheme = "Google";
    })
    .AddCookie("Cookies")
    .AddGoogle(options =>
    {
        options.ClientId = googleAuth["ClientId"]
            ?? throw new InvalidOperationException("GoogleAuth:ClientId not configured");
        options.ClientSecret = googleAuth["ClientSecret"]
            ?? throw new InvalidOperationException("GoogleAuth:ClientSecret not configured");

        // Scopes
        options.Scope.Add("email");
        options.Scope.Add("profile");

        // Workspace Domain Restriction (optional)
        options.ClaimActions.MapJsonKey("hd", "hd");  // hd = hosted domain
    });

// ──────────────────────────────────────────────────────────────
// AUTHORIZATION: Plattform-Rollen aus Google Groups
// ──────────────────────────────────────────────────────────────

builder.Services.AddAuthorizationBuilder()
    .AddPolicy("PlatformAdmin", policy =>
        policy.RequireRole("admin"))
    .AddPolicy("SecurityAdmin", policy =>
        policy.RequireRole("security-admin"))
    .AddPolicy("SupportTier1", policy =>
        policy.RequireRole("support-tier1", "support-tier2", "admin"));

// ──────────────────────────────────────────────────────────────
// SERVICE: Interne Rollen auflösen
// ──────────────────────────────────────────────────────────────

builder.Services.AddScoped<IInternalRoleResolver, GoogleGroupsRoleResolver>();

var app = builder.Build();

// ──────────────────────────────────────────────────────────────
// MIDDLEWARE: Externe Rollen + Tenant-Context für Admin-Panel
// ──────────────────────────────────────────────────────────────

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/login", (context) =>
{
    return Results.Challenge(
        authenticationSchemes: new[] { "Google" },
        redirectUri: "/admin"
    );
});

app.MapGet("/logout", async (context) =>
{
    await context.SignOutAsync("Cookies");
    return Results.Redirect("/");
});

// ──────────────────────────────────────────────────────────────
// ADMIN-PANEL: Nur für interne Rollen
// ──────────────────────────────────────────────────────────────

app.MapGroup("/admin")
    .RequireAuthorization()
    .WithOpenApi()
    .WithName("Admin Panel")
    .WithDescription("Nur für interne Benutzer mit entsprechenden Rollen");

// Admin Dashboard
app.MapGet("/admin", (HttpContext context) =>
    Results.Ok(new
    {
        user = context.User.Identity?.Name,
        roles = context.User.Claims
            .Where(c => c.Type == ClaimTypes.Role)
            .Select(c => c.Value)
            .ToList(),
        email = context.User.FindFirst(ClaimTypes.Email)?.Value,
    })
).RequireAuthorization();

// Tenant-Impersonate Endpoint (nur SupportTier2+)
app.MapPost("/admin/tenant/{tenantId}/impersonate", async (
    string tenantId,
    HttpContext context,
    ITenantService tenantService,
    IAuditService auditService) =>
{
    // 1. Check: Benutzer ist SupportTier2 oder Admin
    if (!context.User.HasClaim(ClaimTypes.Role, "support-tier2") &&
        !context.User.HasClaim(ClaimTypes.Role, "admin"))
    {
        return Results.Forbid();
    }

    // 2. Check: Tenant existiert
    var tenant = await tenantService.GetTenantByIdAsync(tenantId);
    if (tenant == null)
        return Results.NotFound();

    // 3. Audit: Admin impersoniert Tenant
    var adminEmail = context.User.FindFirst(ClaimTypes.Email)?.Value;
    await auditService.LogAsync(new AuditLog
    {
        Action = "admin_impersonate",
        TenantId = tenantId,
        AdminEmail = adminEmail,
        Timestamp = DateTimeOffset.UtcNow,
    });

    // 4. Impersonate-Token erstellen (mit kurzer Gültigkeit, z.B. 1h)
    var token = GenerateImpersonateToken(tenantId, adminEmail, expirationMinutes: 60);

    return Results.Ok(new { token, tenant_id = tenantId, expires_in = 3600 });
})
.RequireAuthorization("SupportTier1");
```

### 2. Services: Google Groups auflösen

```csharp
// Services/GoogleGroupsRoleResolver.cs

public interface IInternalRoleResolver
{
    Task<List<string>> ResolveRolesAsync(string email);
}

public class GoogleGroupsRoleResolver : IInternalRoleResolver
{
    private readonly GoogleServiceAccountCredential _credential;
    private readonly DirectoryService _directoryService;

    public GoogleGroupsRoleResolver(IConfiguration config)
    {
        // Nutze Service Account für Google Admin API (Directory API)
        var serviceAccountJson = config["GoogleAuth:ServiceAccountJson"];
        var credential = GoogleCredential
            .FromJson(serviceAccountJson)
            .CreateScoped(DirectoryService.Scope.AdminDirectoryGroupReadonly);

        _directoryService = new DirectoryService(new BaseClientService.Initializer
        {
            HttpClientInitializer = credential,
        });
    }

    public async Task<List<string>> ResolveRolesAsync(string email)
    {
        var roles = new List<string>();

        try
        {
            // Finde alle Groups, denen dieser User angehört
            var groups = await _directoryService.Groups
                .List()
                .SetQuery($"memberKey='{email}'")
                .ExecuteAsync();

            foreach (var group in groups.GroupsValue ?? new List<Group>())
            {
                // Map Group → Role
                var role = group.Email switch
                {
                    "navosec-platform-admins@euereFirma.de" => "admin",
                    "navosec-security-admins@euereFirma.de" => "security-admin",
                    "navosec-support@euereFirma.de" => "support-tier1",
                    "navosec-support-tier2@euereFirma.de" => "support-tier2",
                    _ => null
                };

                if (role != null)
                    roles.Add(role);
            }
        }
        catch (Exception ex)
        {
            // Log und fallback
            Console.WriteLine($"Failed to resolve roles for {email}: {ex.Message}");
        }

        return roles;
    }
}
```

### 3. Middleware: Google Groups als Claims

```csharp
// Middleware/GoogleGroupsClaimMiddleware.cs

public class GoogleGroupsClaimMiddleware
{
    private readonly RequestDelegate _next;
    private readonly IInternalRoleResolver _roleResolver;

    public GoogleGroupsClaimMiddleware(RequestDelegate next, IInternalRoleResolver roleResolver)
    {
        _next = next;
        _roleResolver = roleResolver;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (context.User.Identity?.IsAuthenticated == true)
        {
            var email = context.User.FindFirst(ClaimTypes.Email)?.Value;
            if (email != null)
            {
                // Lade Rollen aus Google Groups
                var roles = await _roleResolver.ResolveRolesAsync(email);

                // Füge Rollen als Claims hinzu
                var identity = (ClaimsIdentity)context.User.Identity;
                foreach (var role in roles)
                {
                    identity.AddClaim(new Claim(ClaimTypes.Role, role));
                }
            }
        }

        await _next(context);
    }
}

// In Program.cs:
app.UseMiddleware<GoogleGroupsClaimMiddleware>();
```

---

## appsettings.json

```json
{
  "GoogleAuth": {
    "ClientId": "YOUR_CLIENT_ID.apps.googleusercontent.com",
    "ClientSecret": "YOUR_CLIENT_SECRET",
    "ServiceAccountJson": "{...service account json...}",
    "WorkspaceDomain": "euereFirma.de"
  },
  "AdminPanel": {
    "AllowedDomains": ["euereFirma.de"],
    "ImpersonateSessionDurationMinutes": 60,
    "RequireMFA": true
  }
}
```

---

## Sicherheit & Best Practices

### 1. Workspace Domain Restriction

Prüfe, dass `hd` (hosted domain) Claim = deine Workspace Domain ist:

```csharp
if (context.User.FindFirst("hd")?.Value != "euereFirma.de")
{
    return Results.Forbid();  // Nur interne Benutzer
}
```

### 2. Audit Logging

Alle Admin-Aktionen müssen auditiert sein:
- Admin Login
- Admin Logout
- Admin impersoniert Tenant
- Admin ändert Tenant-Settings

```csharp
app.UseMiddleware<AdminAuditMiddleware>();
```

### 3. Role-Based Access Control (RBAC)

```csharp
[Authorize(Roles = "admin,security-admin")]
public IActionResult AdminDashboard() => Ok("Admin Bereich");

[Authorize(Roles = "support-tier1,support-tier2,admin")]
public IActionResult SupportPanel() => Ok("Support Bereich");
```

### 4. MFA Enforcement

Optionally erzwinge MFA für bestimmte Aktionen:

```csharp
if (!context.User.Claims.Any(c => c.Type == "amr" && c.Value.Contains("mfa")))
{
    return Results.Forbid();  // Nur mit MFA
}
```

---

## Kubernetes Secrets für Google OAuth2

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: google-oauth-secret
  namespace: navosec-prod
type: Opaque
stringData:
  client_id: "YOUR_CLIENT_ID.apps.googleusercontent.com"
  client_secret: "YOUR_CLIENT_SECRET"
  service_account_json: |
    {
      "type": "service_account",
      "project_id": "navosec-platform",
      ...
    }
```

---

## Nächste Schritte

1. ✅ Google Cloud Project erstellen + OAuth2 Credentials
2. ✅ Google Workspace Groups für Rollen erstellen
3. → **Implementiere Google OAuth2 in der App (Program.cs)**
4. → **Baue Tenant-Management Jobs (Kubernetes CronJobs)**
5. → **Multi-Tenant Database Setup (Terraform)**

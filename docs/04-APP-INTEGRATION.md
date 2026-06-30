# 04-APP-INTEGRATION.md – Tenant Detection & Multi-Tenancy in der bestehenden App

## Überblick

Die bestehende App muss **tenant-fähig** werden. Das heißt:

1. **Tenant-Erkennung**: Aus Host-Header (kunde1.meinedomain.de) den Tenant auflösen
2. **Tenant-Kontext**: Überall in der App verfügbar (HttpContext, DI)
3. **DB-Connection**: Pro Tenant oder Shared, aber mit TenantId-Filter
4. **Auth + Authz**: JWT muss Tenant enthalten, Match validieren
5. **Health Checks**: Tenant-spezifisch (DB für diesen Tenant prüfen)
6. **Init Container**: Optional auf Tenant-DB warten

Diese Integration sollte **minimale Änderungen** an der bestehenden Architektur erfordern. Das Modular Monolith Modell passt perfekt.

---

## Step 1: Tenant Detection Middleware (Program.cs)

```csharp
// Program.cs

var builder = WebApplication.CreateBuilder(args);

// ──────────────────────────────────────────────────────────────────
// 1. SERVICES: Tenant Registry & Resolution
// ──────────────────────────────────────────────────────────────────

builder.Services.AddScoped<ITenantRegistry, TenantRegistry>();
builder.Services.AddScoped<ITenantResolver, TenantResolver>();
builder.Services.AddScoped<ITenantContext, TenantContext>();

// ──────────────────────────────────────────────────────────────────
// 2. DATABASE: DbContext Factory (pro Tenant)
// ──────────────────────────────────────────────────────────────────

builder.Services.AddScoped<IDbContextFactory<AppDbContext>>(provider =>
{
    var tenantContext = provider.GetRequiredService<ITenantContext>();
    var configuration = provider.GetRequiredService<IConfiguration>();

    return new AppDbContextFactory(tenantContext, configuration);
});

var app = builder.Build();

// ──────────────────────────────────────────────────────────────────
// 3. MIDDLEWARE PIPELINE
// ──────────────────────────────────────────────────────────────────

// 📌 WICHTIG: Tenant Detection muss SEHR FRÜH laufen (vor Auth!)
app.UseMiddleware<TenantDetectionMiddleware>();

// Standard Middleware
app.UseAuthentication();
app.UseAuthorization();

// Nach Auth: Validiere dass Tenant-Claim mit Host-Header matched
app.UseMiddleware<TenantMatchValidationMiddleware>();

// Weitere Middleware
app.UseForwardedHeaders();  // Von Traefik: X-Forwarded-Host, etc.

app.MapControllers();
app.MapHealthChecks("/health");

app.Run();
```

---

## Step 2: Tenant Detection Middleware

```csharp
// Middleware/TenantDetectionMiddleware.cs

public class TenantDetectionMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<TenantDetectionMiddleware> _logger;

    public TenantDetectionMiddleware(RequestDelegate next, ILogger<TenantDetectionMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context, ITenantResolver tenantResolver)
    {
        try
        {
            // 1. Extract Hostname
            var host = context.Request.Host.Host;  // z.B. "kunde1.meinedomain.de"
            _logger.LogInformation("Request host: {Host}", host);

            // 2. Resolve Tenant
            var tenant = await tenantResolver.ResolveTenantAsync(host);

            if (tenant == null)
            {
                _logger.LogWarning("Tenant not found for host: {Host}", host);
                // Fallback: Landing Page oder redirect
                context.Response.StatusCode = StatusCodes.Status404NotFound;
                await context.Response.WriteAsync("Tenant not found");
                return;
            }

            // 3. Store in HttpContext
            context.Items["Tenant"] = tenant;
            context.Items["TenantId"] = tenant.Id;
            context.Items["TenantDomain"] = tenant.Subdomain;

            _logger.LogInformation("Tenant resolved: {TenantId} ({TenantName})", tenant.Id, tenant.DisplayName);

            await _next(context);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in TenantDetectionMiddleware");
            context.Response.StatusCode = StatusCodes.Status500InternalServerError;
            await context.Response.WriteAsync("Internal error");
        }
    }
}
```

---

## Step 3: Tenant Resolver Service

```csharp
// Services/TenantResolver.cs

public interface ITenantResolver
{
    Task<Tenant?> ResolveTenantAsync(string hostname);
}

public class TenantResolver : ITenantResolver
{
    private readonly IDistributedCache _cache;
    private readonly AppDbContext _dbContext;
    private readonly ILogger<TenantResolver> _logger;
    private const string CacheKeyPrefix = "tenant:";

    public TenantResolver(IDistributedCache cache, AppDbContext dbContext, ILogger<TenantResolver> logger)
    {
        _cache = cache;
        _dbContext = dbContext;
        _logger = logger;
    }

    public async Task<Tenant?> ResolveTenantAsync(string hostname)
    {
        // 1. Extrahiere Subdomain aus Hostname
        var subdomain = ExtractSubdomain(hostname);  // "kunde1" aus "kunde1.meinedomain.de"

        if (string.IsNullOrEmpty(subdomain))
        {
            _logger.LogWarning("Could not extract subdomain from hostname: {Hostname}", hostname);
            return null;
        }

        // 2. Prüfe Cache
        var cacheKey = $"{CacheKeyPrefix}{subdomain}";
        var cached = await _cache.GetStringAsync(cacheKey);
        if (cached != null)
        {
            return JsonSerializer.Deserialize<Tenant>(cached);
        }

        // 3. Lookup in Datenbank
        var tenant = await _dbContext.Tenants
            .AsNoTracking()
            .FirstOrDefaultAsync(t => t.Subdomain == subdomain && t.Status == "Active");

        if (tenant == null)
        {
            _logger.LogWarning("Tenant not found in database: subdomain={Subdomain}", subdomain);
            return null;
        }

        // 4. Cache für 1 Stunde
        var serialized = JsonSerializer.Serialize(tenant);
        await _cache.SetStringAsync(cacheKey, serialized, new DistributedCacheEntryOptions
        {
            AbsoluteExpirationRelativeToNow = TimeSpan.FromHours(1)
        });

        return tenant;
    }

    private static string? ExtractSubdomain(string hostname)
    {
        // "kunde1.meinedomain.de" → "kunde1"
        // "meinedomain.de" → null (keine Subdomain)
        // "localhost:5000" → null

        var parts = hostname.Split('.');
        if (parts.Length < 3)  // Minimum: subdomain.domain.tld
            return null;

        return parts[0];
    }
}
```

---

## Step 4: Tenant Context (DI-Pattern)

```csharp
// Services/TenantContext.cs

public interface ITenantContext
{
    Tenant CurrentTenant { get; }
    string CurrentTenantId { get; }
    bool IsInternalAdmin { get; }  // Für interne Benutzer
}

public class TenantContext : ITenantContext
{
    private readonly IHttpContextAccessor _httpContextAccessor;

    public TenantContext(IHttpContextAccessor httpContextAccessor)
    {
        _httpContextAccessor = httpContextAccessor;
    }

    public Tenant CurrentTenant
    {
        get
        {
            var context = _httpContextAccessor.HttpContext;
            if (context?.Items.TryGetValue("Tenant", out var tenant) == true)
                return (Tenant)tenant!;

            throw new InvalidOperationException("Tenant not found in HttpContext. TenantDetectionMiddleware not configured?");
        }
    }

    public string CurrentTenantId => CurrentTenant.Id;

    public bool IsInternalAdmin
    {
        get
        {
            var context = _httpContextAccessor.HttpContext;
            return context?.User.HasClaim("hd", "euereFirma.de") == true;  // Google Workspace
        }
    }
}
```

---

## Step 5: Protected Base Repository

```csharp
// Repositories/BaseRepository.cs

public abstract class BaseRepository<T, TId> where T : Entity<TId>
{
    protected readonly AppDbContext DbContext;
    protected readonly ITenantContext TenantContext;

    protected BaseRepository(AppDbContext dbContext, ITenantContext tenantContext)
    {
        DbContext = dbContext;
        TenantContext = tenantContext;
    }

    /// <summary>
    /// Alle Queries müssen automatisch nach CurrentTenant gefiltert werden.
    /// </summary>
    protected virtual IQueryable<T> ApplyTenantFilter(IQueryable<T> query)
    {
        // 1. Check: Entität hat TenantId Property
        var tenantIdProperty = typeof(T).GetProperty("TenantId");
        if (tenantIdProperty == null)
        {
            // Falls Entity keine TenantId hat (z.B. GlobalSettings)
            // → Nur interne Admins dürfen zugreifen
            if (!TenantContext.IsInternalAdmin)
                return query.Where(x => false);  // Empty result

            return query;  // Interne Admins sehen alles
        }

        // 2. Filter: WHERE TenantId = CurrentTenant.Id
        var tenantId = TenantContext.CurrentTenantId;
        var parameter = Expression.Parameter(typeof(T));
        var property = Expression.Property(parameter, "TenantId");
        var constant = Expression.Constant(tenantId);
        var equals = Expression.Equal(property, constant);
        var lambda = Expression.Lambda<Func<T, bool>>(equals, parameter);

        return query.Where(lambda);
    }

    // Standard CRUD Operations mit automatischem Tenant-Filter
    public virtual async Task<T?> GetByIdAsync(TId id)
    {
        return await ApplyTenantFilter(DbContext.Set<T>())
            .FirstOrDefaultAsync(x => x.Id!.Equals(id));
    }

    public virtual async Task<List<T>> GetAllAsync()
    {
        return await ApplyTenantFilter(DbContext.Set<T>())
            .ToListAsync();
    }

    public virtual async Task AddAsync(T entity)
    {
        // ✅ Automatisch TenantId setzen
        if (typeof(T).GetProperty("TenantId") is { } prop)
        {
            prop.SetValue(entity, TenantContext.CurrentTenantId);
        }

        DbContext.Set<T>().Add(entity);
        await DbContext.SaveChangesAsync();
    }

    // DELETE: Mit Tenant-Filter
    public virtual async Task DeleteAsync(TId id)
    {
        var entity = await GetByIdAsync(id);
        if (entity != null)
        {
            DbContext.Set<T>().Remove(entity);
            await DbContext.SaveChangesAsync();
        }
    }
}
```

---

## Step 6: DbContext Factory (Multi-Tenant DB Support)

```csharp
// Infrastructure/AppDbContextFactory.cs

public interface IDbContextFactory<out T> where T : DbContext
{
    T CreateDbContext();
}

public class AppDbContextFactory : IDbContextFactory<AppDbContext>
{
    private readonly ITenantContext _tenantContext;
    private readonly IConfiguration _configuration;

    public AppDbContextFactory(ITenantContext tenantContext, IConfiguration configuration)
    {
        _tenantContext = tenantContext;
        _configuration = configuration;
    }

    public AppDbContext CreateDbContext()
    {
        var optionsBuilder = new DbContextOptionsBuilder<AppDbContext>();

        // ──────────────────────────────────────────────────────────────────
        // STRATEGIE 1: Shared Database (alle Tenants in einer DB)
        // ──────────────────────────────────────────────────────────────────

        var connectionString = _configuration.GetConnectionString("DefaultConnection");
        optionsBuilder.UseNpgsql(connectionString);

        // ──────────────────────────────────────────────────────────────────
        // STRATEGIE 2: Per-Tenant Database
        // (Uncomment wenn pro Tenant separate DB gewünscht)
        // ──────────────────────────────────────────────────────────────────

        // var tenant = _tenantContext.CurrentTenant;
        // if (!string.IsNullOrEmpty(tenant.DatabaseConnection))
        // {
        //     // Tenant hat eigene DB Connection
        //     optionsBuilder.UseNpgsql(tenant.DatabaseConnection);
        // }
        // else
        // {
        //     // Fallback auf Shared DB
        //     optionsBuilder.UseNpgsql(connectionString);
        // }

        return new AppDbContext(optionsBuilder.Options);
    }
}
```

---

## Step 7: Health Check (Tenant-spezifisch)

```csharp
// Health/TenantHealthCheck.cs

public class TenantHealthCheck : IHealthCheck
{
    private readonly IDbContextFactory<AppDbContext> _dbContextFactory;
    private readonly ITenantContext _tenantContext;

    public TenantHealthCheck(IDbContextFactory<AppDbContext> dbContextFactory, ITenantContext tenantContext)
    {
        _dbContextFactory = dbContextFactory;
        _tenantContext = tenantContext;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            var dbContext = _dbContextFactory.CreateDbContext();
            var canConnect = await dbContext.Database.CanConnectAsync(cancellationToken);

            if (!canConnect)
                return HealthCheckResult.Unhealthy($"Cannot connect to tenant database: {_tenantContext.CurrentTenantId}");

            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy($"Health check failed for tenant {_tenantContext.CurrentTenantId}: {ex.Message}");
        }
    }
}

// In Program.cs:
builder.Services.AddHealthChecks()
    .AddCheck<TenantHealthCheck>("tenant-db");
```

---

## Step 8: Init Container für Tenant-DB (Optional)

```dockerfile
# Dockerfile für Init Container
# Prüft ob Tenant-DB ready ist

FROM postgres:16-alpine

RUN apk add --no-cache bash

COPY wait-for-tenant-db.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/wait-for-tenant-db.sh

ENTRYPOINT ["/usr/local/bin/wait-for-tenant-db.sh"]
```

```bash
#!/bin/bash
# wait-for-tenant-db.sh

set -e

# Warte bis Tenant-DB erreichbar ist
for i in {1..120}; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        echo "✅ Tenant DB is ready"
        exit 0
    fi
    echo "Waiting for tenant DB ($i/120)..."
    sleep 2
done

echo "❌ Tenant DB not ready in time"
exit 1
```

```yaml
# In Deployment Template
spec:
  initContainers:
    - name: wait-for-tenant-db
      image: wait-for-tenant-db:latest
      env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: tenant-$(TENANT_ID)-db
              key: host
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: tenant-$(TENANT_ID)-db
              key: port
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: tenant-$(TENANT_ID)-db
              key: username
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: tenant-$(TENANT_ID)-db
              key: database
```

---

## Step 9: Existierende Module mit Tenant-Support

Jedes bestehende Module muss **minimal** angepasst werden:

```csharp
// Beispiel: Identity Module

namespace Identity.Application.UseCases.Commands;

public class LoginCommand : IRequest<Result<LoginResponse>>
{
    public string Email { get; set; } = null!;
    public string Password { get; set; } = null!;
}

public class LoginCommandHandler : IRequestHandler<LoginCommand, Result<LoginResponse>>
{
    private readonly IUserRepository _userRepository;  // ← nutzt BaseRepository
    private readonly IJwtService _jwtService;
    private readonly ITenantContext _tenantContext;    // ← Tenant verfügbar

    public async Task<Result<LoginResponse>> Handle(LoginCommand request, CancellationToken ct)
    {
        // 1. User lookup mit automatischem Tenant-Filter
        var user = await _userRepository.FindByEmailAsync(request.Email);
        if (user == null)
            return Result.NotFound("User not found");

        // 2. Generate JWT mit Tenant-Claim
        var token = _jwtService.GenerateToken(user, _tenantContext.CurrentTenant);

        return Result.Success(new LoginResponse { Token = token });
    }
}
```

---

## Migration vom alten k8s/ zum neuen k8s-ng/

| Aspekt | Alter k8s/ | Neuer k8s-ng/ | Aktion |
|--------|-----------|--------------|--------|
| **Deployment** | YAML manual | Kustomize (base + overlays) | Update Deployment Spec |
| **Database** | Eine PostgreSQL | Pro Tenant | DbContextFactory updaten |
| **Ingress** | Eine Host-Rule | Pro Tenant (dynamisch) | Tenant-Creation Job erstellt |
| **Health Checks** | Generisch | Tenant-spezifisch | TenantHealthCheck hinzufügen |
| **Init Container** | Warte auf single DB | Warte auf Tenant-DB | Init-Script updaten |
| **Secrets** | Eine set | Pro Tenant | Secret per Tenant erstellt |
| **Monitoring** | Cluster-Level | Tenant-Level | Labels hinzufügen |

---

## Checklist: Tenant-fähig machen

- [ ] TenantDetectionMiddleware implementieren
- [ ] TenantMatchValidationMiddleware implementieren
- [ ] ITenantContext + ITenantResolver Services registrieren
- [ ] BaseRepository mit Tenant-Filter erweitern
- [ ] DbContextFactory für Multi-Tenant-DB
- [ ] TenantHealthCheck implementieren
- [ ] Auth: JWT mit Tenant-Claim
- [ ] Init Container Optional
- [ ] Tests: Tenant-Isolation validieren
- [ ] Dokumentation aktualisieren

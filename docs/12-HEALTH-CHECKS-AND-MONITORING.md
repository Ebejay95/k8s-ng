# 12-HEALTH-CHECKS-AND-MONITORING.md – Comprehensive Health & Readiness Checks

## Überblick

Health Checks auf **mehreren Ebenen:**

1. **Pod Level**: Liveness + Readiness Probes
2. **App Level**: /health Endpoints (auch wenn DB später nachgezogen wird)
3. **Infrastructure Level**: Node Health, Storage Health
4. **Tenant Level**: Tenant-DB Accessibility
5. **External Level**: Load Balancer Health Checks

---

## 1. Liveness & Readiness Probes (App Deployment)

```yaml
# k8s-ng/app/templates/deployment-healthchecks.yaml

apiVersion: apps/v1
kind: Deployment
metadata:
  name: navosec-app
  namespace: navosec-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: navosec-app
  template:
    metadata:
      labels:
        app: navosec-app
    spec:
      serviceAccountName: navosec-app

      # Init Container: Warte auf Datenbank
      initContainers:
        - name: wait-for-tenant-db
          image: busybox:1.35
          command:
            - 'sh'
            - '-c'
            - |
              for i in {1..120}; do
                if nc -z ${DB_HOST} ${DB_PORT} 2>/dev/null; then
                  echo "✅ DB is ready"
                  exit 0
                fi
                echo "Waiting for DB ($i/120)..."
                sleep 2
              done
              echo "❌ DB timeout"
              exit 1
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

      containers:
        - name: app
          image: ghcr.io/yourorg/navosec-web:latest
          ports:
            - name: http
              containerPort: 8080

          # ──────────────────────────────────────────────────────────────
          # READINESS: Pod ready für Traffic?
          # ──────────────────────────────────────────────────────────────
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 10    # Warte vor erste Check
            periodSeconds: 5           # Alle 5s prüfen
            timeoutSeconds: 3
            failureThreshold: 3        # 3x fehlgeschlagen = not ready
            successThreshold: 1        # 1x erfolgreich = ready

          # ──────────────────────────────────────────────────────────────
          # LIVENESS: Pod noch am Leben?
          # ──────────────────────────────────────────────────────────────
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
              scheme: HTTP
            initialDelaySeconds: 30    # Gib App Zeit zu starten
            periodSeconds: 10          # Alle 10s prüfen
            timeoutSeconds: 5
            failureThreshold: 3        # 3x fehlgeschlagen = Restart

          # ──────────────────────────────────────────────────────────────
          # STARTUP: Erst nach Startup-Check starte Liveness
          # ──────────────────────────────────────────────────────────────
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
              scheme: HTTP
            failureThreshold: 30       # Max 30 * 10 = 300s Startup Zeit
            periodSeconds: 10

          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "500m"

          # Graceful Shutdown
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15 && /app/health-shutdown.sh"]
```

---

## 2. Health Check Endpoints (C# ASP.NET)

```csharp
// src/Api/Health/HealthCheckExtensions.cs

public static class HealthCheckExtensions
{
    public static IServiceCollection AddCustomHealthChecks(this IServiceCollection services, IConfiguration config)
    {
        var hcBuilder = services.AddHealthChecks();

        // ──────────────────────────────────────────────────────────────
        // 1. STARTUP Check (Only during initialization)
        // ──────────────────────────────────────────────────────────────
        hcBuilder
            .AddCheck("startup", new StartupHealthCheck());

        // ──────────────────────────────────────────────────────────────
        // 2. LIVENESS Check (Is the app still running?)
        // ──────────────────────────────────────────────────────────────
        hcBuilder
            .AddCheck("liveness", new LivenessHealthCheck(), tags: new[] { "live" });

        // ──────────────────────────────────────────────────────────────
        // 3. READINESS Check (Can handle requests?)
        // ──────────────────────────────────────────────────────────────

        // 3a. Database Connection
        var connectionString = config.GetConnectionString("DefaultConnection");
        hcBuilder.AddNpgSql(
            connectionString,
            name: "database",
            tags: new[] { "ready", "critical" });

        // 3b. Tenant Database (pro Tenant)
        hcBuilder.AddCheck<TenantDatabaseHealthCheck>(
            "tenant-database",
            tags: new[] { "ready", "critical" });

        // 3c. Redis (SignalR Backplane)
        var redisConnection = config.GetConnectionString("Redis");
        if (!string.IsNullOrEmpty(redisConnection))
        {
            hcBuilder.AddRedis(
                redisConnection,
                name: "redis",
                tags: new[] { "ready" });
        }

        // 3d. External Services (Google OAuth, Mail)
        hcBuilder.AddCheck<GoogleOAuthHealthCheck>(
            "google-oauth",
            tags: new[] { "ready", "external" });

        hcBuilder.AddCheck<SmtpHealthCheck>(
            "smtp",
            tags: new[] { "ready", "external" });

        // 3e. Minio/S3 Storage
        hcBuilder.AddCheck<MinioHealthCheck>(
            "minio-storage",
            tags: new[] { "ready", "external" });

        return services;
    }
}

// ──────────────────────────────────────────────────────────────────
// 1. STARTUP CHECK
// ──────────────────────────────────────────────────────────────────

public class StartupHealthCheck : IHealthCheck
{
    private static bool _initialized = false;

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        // Beim Start: Initialisierung durchführen
        if (!_initialized)
        {
            _initialized = true;
            return Task.FromResult(HealthCheckResult.Healthy("Initialization complete"));
        }

        return Task.FromResult(HealthCheckResult.Healthy());
    }
}

// ──────────────────────────────────────────────────────────────────
// 2. LIVENESS CHECK
// ──────────────────────────────────────────────────────────────────

public class LivenessHealthCheck : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        // Einfacher Check: Ist der Process noch am Leben?
        var process = Process.GetCurrentProcess();
        return Task.FromResult(
            process.Responding
                ? HealthCheckResult.Healthy()
                : HealthCheckResult.Unhealthy("Process not responding")
        );
    }
}

// ──────────────────────────────────────────────────────────────────
// 3. TENANT DATABASE CHECK
// ──────────────────────────────────────────────────────────────────

public class TenantDatabaseHealthCheck : IHealthCheck
{
    private readonly IDbContextFactory<AppDbContext> _dbContextFactory;
    private readonly ITenantContext _tenantContext;
    private readonly ILogger<TenantDatabaseHealthCheck> _logger;

    public TenantDatabaseHealthCheck(
        IDbContextFactory<AppDbContext> dbContextFactory,
        ITenantContext tenantContext,
        ILogger<TenantDatabaseHealthCheck> logger)
    {
        _dbContextFactory = dbContextFactory;
        _tenantContext = tenantContext;
        _logger = logger;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            var dbContext = _dbContextFactory.CreateDbContext();
            var canConnect = await dbContext.Database.CanConnectAsync(cancellationToken);

            if (!canConnect)
                return HealthCheckResult.Unhealthy($"Cannot connect to tenant database: {_tenantContext.CurrentTenantId}");

            // Zusätzlich: Migrations Check
            var pendingMigrations = await dbContext.Database.GetPendingMigrationsAsync(cancellationToken);
            if (pendingMigrations.Any())
                return HealthCheckResult.Degraded($"Pending migrations detected for tenant {_tenantContext.CurrentTenantId}");

            return HealthCheckResult.Healthy($"Database OK (tenant: {_tenantContext.CurrentTenantId})");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Tenant database health check failed");
            return HealthCheckResult.Unhealthy($"Database check failed: {ex.Message}");
        }
    }
}

// ──────────────────────────────────────────────────────────────────
// 4. EXTERNAL SERVICE CHECKS
// ──────────────────────────────────────────────────────────────────

public class GoogleOAuthHealthCheck : IHealthCheck
{
    private readonly HttpClient _httpClient;

    public GoogleOAuthHealthCheck(HttpClient httpClient) => _httpClient = httpClient;

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            var response = await _httpClient.GetAsync("https://accounts.google.com/.well-known/openid-configuration", cancellationToken);
            return response.IsSuccessStatusCode
                ? HealthCheckResult.Healthy()
                : HealthCheckResult.Unhealthy("Google OAuth not responding");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy($"Google OAuth check failed: {ex.Message}");
        }
    }
}

public class SmtpHealthCheck : IHealthCheck
{
    private readonly IConfiguration _config;

    public SmtpHealthCheck(IConfiguration config) => _config = config;

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            var smtpHost = _config["Smtp:Host"];
            var smtpPort = int.Parse(_config["Smtp:Port"] ?? "587");

            using (var client = new TcpClient())
            {
                client.Connect(smtpHost, smtpPort);
                client.Close();
            }

            return Task.FromResult(HealthCheckResult.Healthy());
        }
        catch (Exception ex)
        {
            return Task.FromResult(HealthCheckResult.Unhealthy($"SMTP check failed: {ex.Message}"));
        }
    }
}

public class MinioHealthCheck : IHealthCheck
{
    private readonly IMinioClient _minioClient;

    public MinioHealthCheck(IMinioClient minioClient) => _minioClient = minioClient;

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            // Prüfe ob Bucket erreichbar
            var found = await _minioClient.BucketExistsAsync(new BucketExistsArgs().WithBucket("navosec-backups"));
            return found
                ? HealthCheckResult.Healthy()
                : HealthCheckResult.Unhealthy("Minio bucket not found");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy($"Minio check failed: {ex.Message}");
        }
    }
}
```

---

## 3. Health Endpoints (Controllers)

```csharp
// src/Api/Controllers/HealthController.cs

[ApiController]
[Route("[controller]")]
public class HealthController : ControllerBase
{
    private readonly HealthCheckService _healthCheckService;

    public HealthController(HealthCheckService healthCheckService)
    {
        _healthCheckService = healthCheckService;
    }

    // Kubernetes: /health/startup
    [HttpGet("startup")]
    [ProduceResponseType(StatusCodes.Status200OK)]
    [ProduceResponseType(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Startup()
    {
        var report = await _healthCheckService.CheckHealthAsync(new[] { "startup" });
        return report.Status == HealthStatus.Healthy ? Ok() : StatusCode(503);
    }

    // Kubernetes: /health/live
    [HttpGet("live")]
    [ProduceResponseType(StatusCodes.Status200OK)]
    [ProduceResponseType(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Live()
    {
        var report = await _healthCheckService.CheckHealthAsync(new[] { "live" });
        return report.Status == HealthStatus.Healthy ? Ok() : StatusCode(503);
    }

    // Kubernetes: /health/ready
    [HttpGet("ready")]
    [ProduceResponseType(StatusCodes.Status200OK)]
    [ProduceResponseType(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Ready()
    {
        var report = await _healthCheckService.CheckHealthAsync(new[] { "ready" });
        return report.Status == HealthStatus.Healthy ? Ok() : StatusCode(503);
    }

    // Detailliert (für Debugging)
    [HttpGet("detailed")]
    [ProduceResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Detailed()
    {
        var report = await _healthCheckService.CheckHealthAsync();
        return Ok(new
        {
            status = report.Status.ToString(),
            checks = report.Entries.Select(e => new
            {
                name = e.Key,
                status = e.Value.Status.ToString(),
                description = e.Value.Description,
                duration = e.Value.Duration.TotalMilliseconds
            })
        });
    }
}
```

---

## 4. Monitoring Metrics (Prometheus)

```csharp
// src/Api/Middleware/MetricsMiddleware.cs

public class MetricsMiddleware
{
    private static readonly Counter RequestCounter = Counter
        .Create("http_requests_total", "Total HTTP requests", "method", "endpoint", "status");

    private static readonly Histogram RequestDuration = Histogram
        .Create("http_request_duration_seconds", "HTTP request duration", "method", "endpoint");

    private static readonly Gauge ActiveConnections = Gauge
        .Create("active_connections", "Number of active connections");

    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        ActiveConnections.Inc();
        var timer = RequestDuration.Labels(context.Request.Method, context.Request.Path).NewTimer();

        try
        {
            await next(context);
            RequestCounter.Labels(context.Request.Method, context.Request.Path, context.Response.StatusCode.ToString()).Inc();
        }
        finally
        {
            timer.ObserveDuration();
            ActiveConnections.Dec();
        }
    }
}
```

---

## 5. Graceful Shutdown Script

```bash
#!/bin/bash
# src/Api/health-shutdown.sh

set -e

echo "🛑 Starting graceful shutdown..."

# 1. Stop accepting new requests (readiness = false)
curl -X POST http://localhost:8080/health/shutdown || true

# 2. Warte dass bestehende Requests fertig werden
MAX_WAIT=30
ELAPSED=0
while [ $(curl -s http://localhost:8080/metrics | grep -c "active_connections 0" || echo 0) -eq 0 ] && [ $ELAPSED -lt $MAX_WAIT ]; do
  echo "Waiting for active connections to drain ($ELAPSED/$MAX_WAIT)..."
  sleep 1
  ELAPSED=$((ELAPSED+1))
done

# 3. Cleanup (Datenbank-Connections, etc.)
curl -X POST http://localhost:8080/api/shutdown || true

echo "✅ Graceful shutdown complete"
```

---

## 6. Health Alerts (Prometheus)

```yaml
# monitoring/health-alerts.yaml

groups:
  - name: pod-health
    rules:
      - alert: PodNotReady
        expr: kube_pod_status_phase{phase!="Running"} > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.pod }} is not ready"

      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate detected"

      - alert: HealthCheckFailing
        expr: rate(health_check_failures_total[5m]) > 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Health check is failing"
```

---

## Checkliste

- [ ] Startup Probe implementiert
- [ ] Liveness Probe implementiert
- [ ] Readiness Probe implementiert
- [ ] /health/startup Endpoint
- [ ] /health/live Endpoint
- [ ] /health/ready Endpoint
- [ ] Tenant Database Check
- [ ] External Service Checks
- [ ] Graceful Shutdown (preStop Hook)
- [ ] Metrics Middleware
- [ ] Prometheus Alerts
- [ ] Health Check Tests
- [ ] Monitoring Dashboard in Grafana

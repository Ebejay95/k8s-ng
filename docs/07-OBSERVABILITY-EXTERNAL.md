# 07-OBSERVABILITY-EXTERNAL.md – Prometheus, Mimir, Alertmanager (Außerhalb Cluster!)

## Kritische Erkenntnis

**Wenn der Cluster ausfällt, darf das Monitoring NICHT mit ihm ausfallen!**

Deshalb:
- ✅ Prometheus: In separater VM / Hetzner Server
- ✅ Mimir: Long-term Storage (S3-kompatibel via Hetzner Storage)
- ✅ Alertmanager: Externe Receiver (Email, Slack, PagerDuty)
- ✅ Grafana: Optional auch extern oder im Cluster mit Daten von extern

```
Kubernetes Cluster (navosec-prod)
  ├─ Pod: Prometheus Agent (nur scrape + remote_write)
  ├─ Pod: OpenTelemetry Collector (trace exporter)
  └─ ConfigMap: Alert Rules (Prometheus interpretiert lokal)
       │
       ├─ remote_write: http://prometheus.external.local:9090/api/v1/write
       └─ alertmanager: http://alertmanager.external.local:9093
              │
              ▼
External Infrastructure (Hetzner)
  ├─ VM: Prometheus Server (central Scraping + Remote Storage)
  ├─ S3: Mimir (Time Series Database)
  ├─ VM: Alertmanager (Alert Routing)
  ├─ VM: Grafana (Dashboards)
  └─ SMTP Relay (Email)
```

---

## 1. Prometheus Agent (in Cluster)

Nur ein leichter Agent, der Metrics scr apt und remote an externen Prometheus sendet:

```yaml
# observability/prometheus-agent.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    pod-security.kubernetes.io/enforce: baseline

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-agent-config
  namespace: observability
data:
  prometheus.yaml: |
    global:
      scrape_interval: 30s
      remote_write:
        - url: http://prometheus.external.local:9090/api/v1/write
          queue_config:
            capacity: 10000
            max_shards: 200
            max_samples_per_send: 1000

    scrape_configs:
      # 1. Kubernetes API Server
      - job_name: kubernetes-apiservers
        kubernetes_sd_configs:
          - role: endpoints
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
            action: keep
            regex: default;kubernetes;https

      # 2. Kubelet (Node Metrics)
      - job_name: kubernetes-nodes
        kubernetes_sd_configs:
          - role: node
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)

      # 3. Pod Metrics (annotated)
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__

      # 4. App Pods (navosec-app)
      - job_name: navosec-app
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - navosec-prod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            action: keep
            regex: navosec-app
          - source_labels: [__meta_kubernetes_pod_container_port_number]
            action: keep
            regex: "8080"

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-agent
  namespace: observability

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-agent
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/proxy
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - nonResourceURLs:
      - /metrics
      - /metrics/cadvisor
    verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-agent
subjects:
  - kind: ServiceAccount
    name: prometheus-agent
    namespace: observability

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-agent
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-agent
  template:
    metadata:
      labels:
        app: prometheus-agent
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
    spec:
      serviceAccountName: prometheus-agent
      containers:
        - name: prometheus
          image: prom/prometheus:latest
          args:
            - --config.file=/etc/prometheus/prometheus.yaml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=24h
          ports:
            - name: web
              containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: storage
              mountPath: /prometheus
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 9090
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 9090
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: prometheus-agent-config
        - name: storage
          emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-agent
  namespace: observability
spec:
  selector:
    app: prometheus-agent
  ports:
    - name: web
      port: 9090
      targetPort: 9090
  type: ClusterIP
```

---

## 2. Alert Rules (im Cluster interpretiert)

```yaml
# observability/alert-rules.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-alert-rules
  namespace: observability
data:
  alert-rules.yaml: |
    groups:
      - name: navosec-alerts
        interval: 30s
        rules:
          # 1. Pod not Ready
          - alert: PodNotReady
            expr: kube_pod_status_phase{namespace="navosec-prod",phase!="Running"} > 0
            for: 5m
            annotations:
              summary: "Pod {{ $labels.pod }} is not ready"
              severity: warning

          # 2. High Memory Usage
          - alert: HighMemoryUsage
            expr: container_memory_usage_bytes{pod=~"navosec-app.*"} / container_spec_memory_limit_bytes > 0.9
            for: 2m
            annotations:
              summary: "Pod {{ $labels.pod }} memory > 90%"
              severity: critical

          # 3. High CPU Usage
          - alert: HighCPUUsage
            expr: rate(container_cpu_usage_seconds_total{pod=~"navosec-app.*"}[5m]) > 0.8
            for: 2m
            annotations:
              summary: "Pod {{ $labels.pod }} CPU > 80%"
              severity: warning

          # 4. Database Connection Failed
          - alert: DatabaseConnectionFailed
            expr: navosec_app_db_connection_errors_total > 5
            for: 1m
            annotations:
              summary: "{{ $labels.tenant_id }} Database connection failed"
              severity: critical

          # 5. High Latency
          - alert: HighLatency
            expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) > 1
            for: 5m
            annotations:
              summary: "HTTP latency P99 > 1s"
              severity: warning
```

---

## 3. Externe Prometheus Server (Hetzner VM)

```bash
#!/bin/bash
# observability/prometheus-server-setup.sh

# Installation auf Hetzner Ubuntu Server

sudo apt-get update && sudo apt-get install -y prometheus

# Config
sudo tee /etc/prometheus/prometheus.yml > /dev/null <<EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: navosec-prod
    environment: production

# Remote Storage: Mimir (S3)
remote_write:
  - url: http://mimir:9009/api/prom/push
    write_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_.*|process_.*'
        action: drop  # Drop unnecessary metrics

# Alertmanager
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

rule_files:
  - "/etc/prometheus/alert-rules.yaml"

scrape_configs:
  # From Kubernetes Cluster
  - job_name: 'kubernetes'
    static_configs:
      - targets: ['prometheus-agent.observability.svc.cluster.local:9090']
        labels:
          source: kubernetes
EOF

sudo systemctl restart prometheus
```

---

## 4. Alertmanager (External)

```yaml
# observability/alertmanager-external.yaml

global:
  resolve_timeout: 5m
  slack_api_url: 'YOUR_SLACK_WEBHOOK'

templates:
  - '/etc/alertmanager/alert-templates.yaml'

route:
  # Root route
  receiver: 'team-default'
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h

  # Sub-routes
  routes:
    # Critical alerts
    - match:
        severity: critical
      receiver: 'team-critical'
      group_wait: 0s
      repeat_interval: 5m

    # Warnings
    - match:
        severity: warning
      receiver: 'team-warnings'
      repeat_interval: 2h

receivers:
  # Default: Slack
  - name: team-default
    slack_configs:
      - channel: '#platform-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'

  # Critical: Email + Slack + PagerDuty
  - name: team-critical
    email_configs:
      - to: 'ops-critical@euereFirma.de'
        from: 'alerts@meinedomain.de'
        smarthost: 'smtp.meinedomain.de:587'
        auth_username: 'alerts@meinedomain.de'
        auth_password: 'PASSWORD'
    slack_configs:
      - channel: '#critical-alerts'
        title: '🚨 CRITICAL: {{ .GroupLabels.alertname }}'
        color: 'danger'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_KEY'

  # Warnings: Slack
  - name: team-warnings
    slack_configs:
      - channel: '#warnings'
        title: '⚠️ {{ .GroupLabels.alertname }}'
        color: 'warning'

inhibit_rules:
  # Keine Warnings wenn Critical aktiv
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'cluster']
```

---

## 5. Grafana (extern)

```bash
# Installation
docker run -d \
  --name grafana \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=STRONG_PASSWORD \
  -e GF_AUTH_GENERIC_OAUTH_ENABLED=true \
  -e GF_AUTH_GENERIC_OAUTH_CLIENT_ID=YOUR_CLIENT_ID \
  -e GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=YOUR_CLIENT_SECRET \
  -e GF_AUTH_GENERIC_OAUTH_SCOPES=openid,profile,email \
  -e GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://accounts.google.com/o/oauth2/v2/auth \
  -e GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://oauth2.googleapis.com/token \
  grafana/grafana:latest
```

---

## 6. Mimir (Long-term Storage via S3)

```yaml
# observability/mimir-config.yaml

target: all

multitenancy_enabled: false

usage_stats:
  enabled: false

auth:
  type: noop

distributor:
  rate_limiting_enabled: true
  rate_limit_templates:
    templates:
      - pattern: '{namespace="navosec-prod"}'
        limit: 100000

ingester:
  max_chunk_age: 2h

storage:
  engine: blocks

blocks_storage:
  backend: s3
  s3:
    bucket_name: navosec-mimir
    endpoint: s3.meinedomain.de  # Hetzner S3
    access_key_id: YOUR_ACCESS_KEY
    secret_access_key: YOUR_SECRET_KEY
    insecure: false
  tsdb:
    dir: /mimir-tsdb
  bucket_store:
    index_cache:
      backend: memcached
      memcached:
        addresses: memcached:11211
```

---

## Deployment Checklist

- [ ] Prometheus Agent im Cluster deployed
- [ ] Remote Write zu externem Prometheus konfiguriert
- [ ] Alert Rules in ConfigMap
- [ ] Externer Prometheus Server (Hetzner VM) läuft
- [ ] Mimir mit S3 Backend konfiguriert
- [ ] Alertmanager deployed (Email, Slack, PagerDuty)
- [ ] Grafana mit Google OAuth2 configured
- [ ] Dashboards für Cluster + Tenant Metrics
- [ ] Health Checks für Observability Stack

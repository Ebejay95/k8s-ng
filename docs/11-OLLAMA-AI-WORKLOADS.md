# 11-OLLAMA-AI-WORKLOADS.md – GPU-basierte AI Model Serving (Ollama)

## Architektur

```
User Request (z.B. AI Import)
  │
  ├─ App Pods (General) – 8 replicas auf default Nodes
  │   └─ POST /api/ai/import (Request an Ollama)
  │
  ├─ Ollama Pod (GPU Node) – 1-2 replicas
  │   ├─ Model: llama2, mistral, gguf-custom
  │   ├─ Serving über REST API (localhost:11434)
  │   └─ GPU Memory: 24-40 GB (L40, H100)
  │
  └─ PostgreSQL (Results Storage)
      └─ Store inference results, cache
```

---

## 1. GPU Nodes (Hetzner Terraform)

```hcl
# terraform/hetzner/gpu-nodes.tf

# GPU Server (optional, aber für AI empfohlen)
resource "hcloud_server" "gpu" {
  count             = var.enable_gpu_nodes ? var.gpu_node_count : 0
  name              = "${local.cluster_name}-gpu-${count.index + 1}"
  image             = var.talos_image_name
  server_type       = "gpu_l40_1x"  # NVIDIA L40 (48 GB VRAM)
  location          = var.location
  ssh_keys          = [hcloud_ssh_key.default.id]

  labels = merge(
    local.common_labels,
    { "role" = "gpu", "accelerator" = "nvidia-l40" }
  )
}

# Attach GPU zu Private Network
resource "hcloud_server_network" "gpu" {
  count     = var.enable_gpu_nodes ? var.gpu_node_count : 0
  server_id = hcloud_server.gpu[count.index].id
  network_id = hcloud_network.main.id
  ip        = "10.0.1.${150 + count.index}"  # 10.0.1.150, 10.0.1.151
}

# GPU Nodes haben Taints (nur Ollama/AI Workloads)
# Diese werden später in Kubernetes NodePool konfiguriert
```

---

## 2. Kubernetes GPU Node Pool

```yaml
# kubernetes/gpu-node-pool.yaml (Talos)

# In Machine Config:
machine:
  kubelet:
    extraArgs:
      nvidia-gpus: all
      node-labels: accelerator=nvidia-l40,workload=ai

# Labels + Taints
labels:
  accelerator: nvidia-l40
  workload: ai

taints:
  - key: gpu
    value: "true"
    effect: NoSchedule
```

---

## 3. NVIDIA GPU Support in Kubernetes

```yaml
# security/nvidia-device-plugin.yaml

apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      nodeSelector:
        accelerator: nvidia-l40
      priorityClassName: system-node-critical
      containers:
        - image: nvidia/k8s-device-plugin:v0.14.0
          name: nvidia-device-plugin-ctr
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          resources:
            limits:
              cpu: 100m
              memory: 32Mi
            requests:
              cpu: 100m
              memory: 32Mi
          volumeMounts:
            - name: device-metrics
              mountPath: /run/prometheus
      volumes:
        - name: device-metrics
          emptyDir: {}
```

---

## 4. Ollama Deployment

```yaml
# ollama/deployment.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: ai

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ai
spec:
  replicas: 1  # GPU wird durch Replicas limitiert
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
        workload: ai
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "11434"
    spec:
      # GPU Scheduling
      nodeSelector:
        accelerator: nvidia-l40
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule

      containers:
        - name: ollama
          image: ollama/ollama:latest
          ports:
            - name: http
              containerPort: 11434
          resources:
            requests:
              nvidia.com/gpu: 1  # 1x GPU
              memory: "32Gi"
              cpu: "4"
            limits:
              nvidia.com/gpu: 1
              memory: "40Gi"
              cpu: "8"
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
            - name: cache
              mountPath: /tmp/ollama-cache
          livenessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 10
            periodSeconds: 5

      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models-pvc
        - name: cache
          emptyDir: {}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models-pvc
  namespace: ai
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi  # Für mehrere Models

---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ai
spec:
  selector:
    app: ollama
  ports:
    - name: http
      port: 11434
      targetPort: 11434
  type: ClusterIP
```

---

## 5. Model Management

```bash
#!/bin/bash
# ollama/load-models.sh

# Wird nach Ollama Deployment ausgeführt

OLLAMA_POD=$(kubectl get pod -n ai -l app=ollama -o jsonpath='{.items[0].metadata.name}')

# Pull Models
kubectl exec -it $OLLAMA_POD -n ai -- ollama pull llama2
kubectl exec -it $OLLAMA_POD -n ai -- ollama pull mistral
kubectl exec -it $OLLAMA_POD -n ai -- ollama pull neural-chat

# List Models
kubectl exec $OLLAMA_POD -n ai -- ollama list
```

---

## 6. App Integration (C# -> Ollama)

```csharp
// src/AiImport/Services/OllamaService.cs

public interface IOllamaService
{
    Task<string> GenerateAsync(string prompt, string model = "llama2");
    Task<List<OllamaModel>> GetAvailableModelsAsync();
}

public class OllamaService : IOllamaService
{
    private readonly HttpClient _httpClient;
    private readonly ILogger<OllamaService> _logger;
    private const string OllamaBaseUrl = "http://ollama.ai.svc.cluster.local:11434";

    public OllamaService(HttpClient httpClient, ILogger<OllamaService> logger)
    {
        _httpClient = httpClient;
        _logger = logger;
        _httpClient.BaseAddress = new Uri(OllamaBaseUrl);
    }

    public async Task<string> GenerateAsync(string prompt, string model = "llama2")
    {
        try
        {
            var request = new
            {
                model = model,
                prompt = prompt,
                stream = false,
                temperature = 0.7,
                top_p = 0.9,
                top_k = 40,
            };

            var response = await _httpClient.PostAsJsonAsync("/api/generate", request);
            var content = await response.Content.ReadAsStringAsync();

            var result = JsonSerializer.Deserialize<OllamaResponse>(content);
            _logger.LogInformation("Ollama generation completed in {Duration}ms", result?.ResponseTime ?? 0);

            return result?.Response ?? string.Empty;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Ollama generation failed");
            throw;
        }
    }

    public async Task<List<OllamaModel>> GetAvailableModelsAsync()
    {
        var response = await _httpClient.GetAsync("/api/tags");
        var content = await response.Content.ReadAsStringAsync();
        var result = JsonSerializer.Deserialize<OllamaModelsResponse>(content);

        return result?.Models ?? new List<OllamaModel>();
    }
}

// DTOs
public class OllamaResponse
{
    [JsonPropertyName("response")]
    public string Response { get; set; } = string.Empty;

    [JsonPropertyName("total_duration")]
    public long TotalDuration { get; set; }

    public int ResponseTime => (int)(TotalDuration / 1_000_000);  // To milliseconds
}

public class OllamaModel
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("modified_at")]
    public DateTime ModifiedAt { get; set; }
}

// In Program.cs:
builder.Services.AddHttpClient<IOllamaService, OllamaService>();
```

---

## 7. Monitoring Ollama (GPU Metrics)

```yaml
# ollama/monitoring.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: ollama-metrics-exporter
  namespace: ai
data:
  exporter.sh: |
    #!/bin/bash
    while true; do
      # GPU Memory Usage
      nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \
        | awk '{print "ollama_gpu_memory_used_mb " $1}'

      # GPU Utilization
      nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits \
        | awk '{print "ollama_gpu_utilization_percent " $1}'

      # Temperature
      nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits \
        | awk '{print "ollama_gpu_temperature_celsius " $1}'

      sleep 10
    done
```

---

## 8. Cost Optimization

```yaml
# ollama/cost-optimization.yaml

apiVersion: v1
kind: Pod
metadata:
  name: ollama-cost-monitor
spec:
  containers:
    - name: monitor
      image: bash:5.2
      command:
        - /bin/bash
        - -c
        - |
          # Scale down GPU wenn nicht in Nutzung
          while true; do
            # Prüfe letzte Anfrage-Zeit
            LAST_REQUEST=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
            if [ "$LAST_REQUEST" -gt 3600 ]; then
              # Keine Anfrage in letzte Stunde
              kubectl scale deployment ollama --replicas=0 -n ai
            fi
            sleep 300
          done
```

---

## 9. Checkliste

- [ ] GPU Nodes deployt (Hetzner)
- [ ] NVIDIA Device Plugin deployed
- [ ] Ollama Deployment läuft
- [ ] Models geladen (llama2, mistral, etc.)
- [ ] Service für Ollama erreichbar
- [ ] App integriert OllamaService
- [ ] GPU Monitoring aktiv
- [ ] Health Checks konfiguriert
- [ ] Cost Optimization Rules

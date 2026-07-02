# 05-SECURITY-BASELINE.md – Pod Security, RBAC, NetworkPolicies, Kyverno, CIS Hardening

## Überblick

Diese Sicherheits-Baseline wird auf den Cluster angewendet und erzwingt:

- **Pod Security Admission (PSA)**: restricted → keine privilegierten Container
- **NetworkPolicies**: Deny-All per Default, nur explizit erlaubter Traffic
- **RBAC**: Minimale Permissions pro Service Account
- **Kyverno**: Policy Engine für CIS Benchmark, Image Scanning, Resource Limits
- **Audit Logging**: Alle API-Calls werden geloggt
- **Secrets Encryption**: etcd at Rest verschlüsselt
- **SELinux / AppArmor**: Optional auf Nodes

---

## 1. Pod Security Admission (PSA) - restricted

```yaml
# security/psa-restricted.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: navosec-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
  annotations:
    pod-security.kubernetes.io/enforce: "true"
spec: {}

---
# Exceptions: Nur system-namespaces und unvermeidlich benötigte Pods
apiVersion: v1
kind: Namespace
metadata:
  name: kyverno
  labels:
    pod-security.kubernetes.io/enforce: baseline  # Kyverno braucht manchmal mehr

---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    pod-security.kubernetes.io/enforce: baseline  # Prometheus etc.
```

**Was PSA-restricted verhindert:**
- ✅ Keine privilegierten Pods
- ✅ Keine Host-Network/Host-PID/Host-IPC
- ✅ Nur read-only root filesystems
- ✅ Keine CAP_SYS_ADMIN und andere dangerous caps
- ✅ Keine Volumes außer: configMap, secret, downwardAPI, emptyDir, projected, etc.

---

## 2. NetworkPolicies – Deny-All + Whitelist

```yaml
# security/network-policies-deny-all.yaml

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: navosec-prod
spec:
  podSelector: {}  # Alle Pods
  policyTypes:
    - Ingress  # Blockiere all inbound traffic

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-egress
  namespace: navosec-prod
spec:
  podSelector: {}  # Alle Pods
  policyTypes:
    - Egress  # Blockiere all outbound traffic

---
# Ausnahmen: Ingress Controller → App Pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-app
  namespace: navosec-prod
spec:
  podSelector:
    matchLabels:
      app: navosec-app
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: traefik  # Oder kube-system je nachdem
      ports:
        - protocol: TCP
          port: 8080

---
# App Pods dürfen zur PostgreSQL DB
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-postgres
  namespace: navosec-prod
spec:
  podSelector:
    matchLabels:
      app: navosec-app
  policyTypes:
    - Egress
  egress:
    # DNS (CoreDNS)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53

    # PostgreSQL (10.0.1.200:5432)
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432

    # External APIs (z.B. Google OAuth, Mail)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 587  # SMTP TLS

---
# Prometheus darf Metrics scrapen
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: navosec-prod
spec:
  podSelector: {}  # Alle Pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: observability
          podSelector:
            matchLabels:
              app: prometheus
      ports:
        - protocol: TCP
          port: 9090
```

---

## 3. RBAC – Minimale Permissions

```yaml
# security/rbac-base.yaml

# ServiceAccount für die App
apiVersion: v1
kind: ServiceAccount
metadata:
  name: navosec-app
  namespace: navosec-prod

---
# Role: Was navosec-app tun darf
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: navosec-app
  namespace: navosec-prod
rules:
  # 1. Secrets lesen (DB-Credentials, JWT-Keys, etc.)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
    resourceNames:
      - "navosec-app-secret"
      - "postgres-secret"
      - "redis-secret"

  # 2. ConfigMaps lesen (Tenant-Konfiguration)
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]

  # 3. Events schreiben (für Audit)
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]

  # 4. Leases (für Leader Election, falls genutzt)
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "create", "update"]
    resourceNames:
      - "navosec-app-leader"

---
# RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
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
# Operator/Admin RBAC (für Argo CD, etc.)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit  # oder cluster-admin bei Bedarf
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
```

---

## 4. Kyverno – Policy Engine (CIS Benchmark)

```yaml
# security/kyverno-policies.yaml

# 1. Policy: Require Resource Limits
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: audit  # Später: enforce
  rules:
    - name: check-resource-limits
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "CPU and memory limits are required"
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"

---
# 2. Policy: Require Non-Root User
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-nonroot-user
spec:
  validationFailureAction: audit
  rules:
    - name: check-nonroot
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Containers must run as non-root"
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
                  runAsUser: "?*"

---
# 3. Policy: Require Read-Only Root Filesystem
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-readonly-root-fs
spec:
  validationFailureAction: audit
  rules:
    - name: check-readonly-root
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Root filesystem must be read-only"
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true

---
# 4. Policy: Forbid Privileged Containers
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: forbid-privileged
spec:
  validationFailureAction: enforce
  rules:
    - name: deny-privileged
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: false

---
# 5. Policy: Require Image Registry Whitelist
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-registry
spec:
  validationFailureAction: enforce
  rules:
    - name: check-registry
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Image must be from approved registry (ghcr.io)"
        pattern:
          spec:
            containers:
              - image: "ghcr.io/*"

---
# 6. Policy: Require Resource Requests
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests
spec:
  validationFailureAction: audit
  rules:
    - name: check-requests
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "CPU and memory requests are required"
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
```

---

## 5. Audit Logging

```yaml
# security/audit-policy.yaml

apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # 1. All requests at Metadata level
  - level: Metadata
    omitStages:
      - RequestReceived

  # 2. Secrets: Full audit (sensitive)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]

  # 3. Tenant Management Jobs: Full audit
  - level: RequestResponse
    resources:
      - group: batch
        resources: ["jobs"]

  # 4. RBAC Changes: Full audit
  - level: RequestResponse
    resources:
      - group: rbac.authorization.k8s.io
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 5. Network Policies: Full audit
  - level: RequestResponse
    resources:
      - group: networking.k8s.io
        resources: ["networkpolicies"]

  # 6. Everything else at Metadata
  - level: Metadata
    omitStages:
      - RequestReceived
```

---

## 6. Encryption at Rest (etcd)

Bereits in Hetzner Talos konfiguriert via:

```
talos/machine/state/encryption/aescbc:
  key: $(openssl rand -base64 32)
```

---

## 7. Admission Controllers

```yaml
# Sicherstellen dass folgende Admission Controller aktiviert sind:
# - PodSecurityPolicy (deprecated, nutze PSA stattdessen)
# - Pod Security Admission (PSA) ✅
# - SecurityContextDeny (deprecated)
# - DenyEscalatingExec ✅ (standard)
# - AlwaysPullImages (optional, empfohlen)
# - ValidatingWebhook (für Kyverno)
# - MutatingWebhook (für Kyverno)

# In Talos: Machine Config
machine:
  kubelet:
    extraArgs:
      admission-control: PodSecurityPolicy,ValidatingWebhookConfiguration,MutatingWebhookConfiguration
```

---

## 8. Sicherheits-Checkliste

- [ ] PSA restricted auf navosec-prod
- [ ] NetworkPolicies: Deny-All + Whitelist
- [ ] RBAC: Minimale Permissions per Service Account
- [ ] Kyverno Policies deployed (audit mode für Start, später enforce)
- [ ] Audit Logging in Kubernetes aktiviert
- [ ] Secrets verschlüsselt in etcd (Talos standard)
- [ ] Image Registry Whitelist enforced
- [ ] Pod Security Policy deprecated, nutze PSA
- [ ] Bastion für administrative Zugriffe
- [ ] TLS überall (Ingress, API, inter-pod)

---

## Deployment

```bash
# Alle Security-Policies anwenden
kubectl apply -f security/

# Kyverno installieren (Helm später)
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace

# Audit Logs prüfen
kubectl logs -n kube-system -l component=kube-apiserver | grep audit
```

---

## BSI IT-Grundschutz APP.4.4 — Umsetzungsnachweis (Kurzreferenz)

| Anforderung | Umsetzung im Repo |
|-------------|-------------------|
| A6 Init-Container | `wait-for-db` initContainer in `admin/30-deployment.yaml` + Tenant-Template |
| A11 Health-Checks | Probes in allen Deployments; Kyverno `require-health-probes` |
| A13 Auditierung | `cluster-config/kube-bench-cronjob.yaml`; Kyverno-Policies auf `Enforce` |
| A3/A12 API-Audit | `talos/patches/controlplane.yaml` (inline `auditPolicy`, Talos setzt `--audit-policy-file`) |
| A3/S6 Storage-RBAC | `security/56-rbac-storage-admin.yaml` |
| A7/S5 + A18/S4 Netz-RBAC | `security/55-rbac-network-admin.yaml` |
| A5 Datensicherung | `backup/10-postgres-backup-cronjob.yaml` (Dump+S3), `backup/20-velero-schedule-example.yaml`, `cluster-config/etcd-snapshot-cronjob.yaml` |
| A19 Hochverfügbarkeit | `topologySpreadConstraints`/AntiAffinity + `admin/65-pdb.yaml` + Tenant-PDB |
| A20 Verschlüsselung at rest | `talos/patches/controlplane.yaml` (`encryption-provider-config` + LUKS2-Disk), `cluster-config/encrypted-storageclass.yaml` |
| A21 Regelmäßiger Restart | `tenant-management/50-scheduled-restart-cronjob.yaml` (täglich, < 24h) |
| A17 Node-Attestierung | siehe `cluster-config/README.md` (TPM/Secure-Boot, Node-Provisioning) |

> Hinweis: Dateien unter `cluster-config/` sind Control-Plane-/Node-Bootstrap
> und bewusst **nicht** Teil von `base/kustomization.yaml`.

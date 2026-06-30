# 06-ARGO-CD-GITOPS.md – GitOps Orchestration mit Argo CD

## Überblick

Argo CD ist die **einzige Quelle der Wahrheit** für deinen Cluster. Alles kommt aus Git:

- App Deployments
- Tenant-Konfigurations-Updates
- Security Policies
- Observability Stack
- Backup & DR Config

**Workflow:**
```
Git Commit
  ↓
GitHub Webhook → Argo CD
  ↓
Argo CD vergleicht Git-Zustand mit Cluster-Zustand
  ↓
Automatic oder Manual Sync (je nach Policy)
  ↓
kubectl apply (Argo CD deployed)
  ↓
Cluster im Soll-Zustand
```

---

## 1. Argo CD Installation

```yaml
# argocd/install.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    pod-security.kubernetes.io/enforce: baseline

---
# Argo CD Helm Chart
# helm repo add argo https://argoproj.github.io/argo-helm
# helm repo update
# helm install argocd argo/argo-cd -f values.yaml

# values.yaml für Argo CD:
server:
  insecure: false  # TLS enforced
  rbac:
    scopes: "[groups]"

configs:
  url: https://argocd.meinedomain.de

  # OIDC für Google OAuth2
  oidc:
    name: Google
    issuer: https://accounts.google.com
    clientID: YOUR_CLIENT_ID
    clientSecret: YOUR_CLIENT_SECRET
    requestedScopes:
      - openid
      - profile
      - email
    requestedIDTokenClaims:
      hd: euereFirma.de  # Restrict to workspace

repoServer:
  replicas: 2

applicationController:
  replicas: 2

redisInst:
  enabled: true
  replicas: 2

notifications:
  enabled: true  # Für Alerts
```

---

## 2. Argo CD AppProjects (Multi-Tenant Isolation)

```yaml
# argocd/app-projects.yaml

# Projekt 1: Platform Services (nur Admins)
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform infrastructure (Argo CD, Kyverno, Ingress, etc.)
  sourceRepos:
    - "https://github.com/yourorg/k8s-ng.git"
  destinations:
    - namespace: "*"
      server: https://kubernetes.default.svc
      name: in-cluster
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: admins
      policies:
        - p, proj:platform:admins, applications, *, platform/*, allow
      groups:
        - navosec-platform-admins

---
# Projekt 2: Applications (Support kann editieren)
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: applications
  namespace: argocd
spec:
  description: Customer applications
  sourceRepos:
    - "https://github.com/yourorg/k8s-ng.git"
  destinations:
    - namespace: "navosec-prod"
      server: https://kubernetes.default.svc
  roles:
    - name: deployments
      policies:
        - p, proj:applications:deployments, applications, *, applications/*, allow
      groups:
        - navosec-support

---
# Projekt 3: Observability (nur Operators)
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: observability
  namespace: argocd
spec:
  description: Monitoring & Logging
  sourceRepos:
    - "https://github.com/yourorg/k8s-ng.git"
  destinations:
    - namespace: observability
      server: https://kubernetes.default.svc
  roles:
    - name: operators
      policies:
        - p, proj:observability:operators, applications, *, observability/*, allow
      groups:
        - navosec-operators
```

---

## 3. Argo CD Applications

```yaml
# argocd/apps/app-navosec-prod.yaml

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: navosec-prod
  namespace: argocd
spec:
  project: applications

  # Source: Git Repository
  source:
    repoURL: https://github.com/yourorg/k8s-ng.git
    targetRevision: main
    path: k8s-ng/app/helm
    helm:
      releaseName: navosec
      values: |
        image: ghcr.io/yourorg/navosec-web:latest
        replicas: 2
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"

  # Destination: Cluster
  destination:
    server: https://kubernetes.default.svc
    namespace: navosec-prod

  # Sync Policy
  syncPolicy:
    automated:
      prune: true  # Delete resources no longer in Git
      selfHeal: true  # Auto-sync if cluster drift detected
    syncOptions:
      - CreateNamespace=true

---
# argocd/apps/security.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: security-baseline
  namespace: argocd
spec:
  project: platform

  source:
    repoURL: https://github.com/yourorg/k8s-ng.git
    targetRevision: main
    path: k8s-ng/security

  destination:
    server: https://kubernetes.default.svc
    namespace: default

  syncPolicy:
    automated:
      prune: true
      selfHeal: true

---
# argocd/apps/kyverno.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: platform

  source:
    repoURL: https://kyverno.github.io/kyverno/
    chart: kyverno
    targetRevision: "3.0.0"
    helm:
      releaseName: kyverno
      values: |
        validationFailureAction: audit
        webhooks:
          validation:
            namespaceSelector:
              matchExpressions:
                - key: pod-security.kubernetes.io/enforce
                  operator: In
                  values: ["restricted"]

  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno

  syncPolicy:
    syncOptions:
      - CreateNamespace=true

---
# argocd/apps/observability.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability
  namespace: argocd
spec:
  project: observability

  source:
    repoURL: https://github.com/yourorg/k8s-ng.git
    targetRevision: main
    path: k8s-ng/observability

  destination:
    server: https://kubernetes.default.svc
    namespace: observability

  syncPolicy:
    automated:
      prune: false  # Vorsicht bei Observability
      selfHeal: false
```

---

## 4. Git Repository Struktur

```
k8s-ng/
├── app/
│   ├── helm/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values-prod.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       └── hpa.yaml
│   └── kustomization.yaml
│
├── security/
│   ├── psa-restricted.yaml
│   ├── network-policies.yaml
│   ├── rbac.yaml
│   ├── kyverno-policies.yaml
│   └── kustomization.yaml
│
├── observability/
│   ├── prometheus/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── mimir/
│   │   └── values.yaml
│   └── kustomization.yaml
│
└── argocd/
    ├── app-projects.yaml
    └── apps/
        ├── app-navosec-prod.yaml
        ├── security.yaml
        ├── kyverno.yaml
        └── observability.yaml
```

---

## 5. Argo CD CLI

```bash
# Installation
brew install argocd

# Login
argocd login argocd.meinedomain.de

# List Applications
argocd app list

# Watch Application Status
argocd app get navosec-prod --watch

# Manually Trigger Sync
argocd app sync navosec-prod

# Rollback to Previous Revision
argocd app rollback navosec-prod 1
```

---

## 6. Notifications & Alerts (Argo CD + Slack)

```yaml
# argocd/notifications.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  trigger.on-health-degraded: |
    - when: app.status.operationState.phase in ['Error'] and app.status.health.status == 'Degraded'
      oncePer: 10m
      send: [health-degraded]

  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error']
      oncePer: 5m
      send: [sync-failed]

  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [sync-succeeded]

  # Slack Template
  template.health-degraded: |
    message: |
      Application {{.app.metadata.name}} health status is {{.app.status.health.status}}
      Sync Status: {{.app.status.sync.status}}
      Repository: {{.app.spec.source.repoURL}}
    slack:
      attachments: |
        [{
          "color": "#f15a24",
          "title": "{{.app.metadata.name}}",
          "actions": [
            {
              "type": "button",
              "text": "View in Argo CD",
              "url": "{{.context.argocdUrl}}/applications/{{.app.metadata.name}}"
            }
          ]
        }]

---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
stringData:
  slack-token: xoxb-YOUR-SLACK-TOKEN
  slack-channel: "#platform-alerts"
```

---

## Architektur: GitOps Workflow

```
┌─────────────────────────────────────────────┐
│ Developer Commit                            │
│ git push main                               │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│ GitHub Webhook                              │
│ → Argo CD Server                            │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│ Argo CD Compares Git vs Cluster             │
│ Detected Drift: image tag = v1.2.0          │
│ Cluster Running: v1.1.0                     │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│ Auto-Sync (or Manual Approval)              │
│ argocd app sync navosec-prod                │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│ kubectl apply                               │
│ Rolling Update: Pull new image              │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│ Health Check                                │
│ Pods Running → Healthy ✅                   │
│ Slack Notification: Sync Successful         │
└─────────────────────────────────────────────┘
```

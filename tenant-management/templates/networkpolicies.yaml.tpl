apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: tenant-__TENANT_ID__
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: tenant-__TENANT_ID__
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
# Nur Traefik darf die Tenant-App erreichen (<tenant>.<domain>)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-traefik
  namespace: tenant-__TENANT_ID__
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
              name: traefik
      ports:
        - protocol: TCP
          port: 8080
---
# Tenant-App Egress: DNS, eigene DB, dediziertes In-Namespace-Ollama, HTTPS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-egress
  namespace: tenant-__TENANT_ID__
spec:
  podSelector:
    matchLabels:
      app: navosec-app
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    - to:
        - ipBlock:
            cidr: __TENANT_DB_CIDR__
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - podSelector:
            matchLabels:
              app: ollama
      ports:
        - protocol: TCP
          port: 11434
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443

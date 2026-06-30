apiVersion: v1
kind: Namespace
metadata:
  name: tenant-__TENANT_ID__
  labels:
    name: tenant-__TENANT_ID__
    tenant.navosec.io/id: __TENANT_ID__
    navosec.io/tier: tenant
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
# default-SA im Tenant-Namespace haertet: kein API-Token-Mount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: tenant-__TENANT_ID__
automountServiceAccountToken: false

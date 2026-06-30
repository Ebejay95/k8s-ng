apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-default-limits
  namespace: tenant-__TENANT_ID__
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-hard-quota
  namespace: tenant-__TENANT_ID__
spec:
  hard:
    requests.cpu: "__RQ_REQUESTS_CPU__"
    requests.memory: __RQ_REQUESTS_MEMORY__
    limits.cpu: "__RQ_LIMITS_CPU__"
    limits.memory: __RQ_LIMITS_MEMORY__
    pods: "__RQ_PODS__"
    persistentvolumeclaims: "__RQ_PVCS__"

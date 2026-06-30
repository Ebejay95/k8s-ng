apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tenant-db-secret
  namespace: tenant-__TENANT_ID__
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: bitwarden-fields
    kind: ClusterSecretStore
  target:
    name: tenant-db-secret
    creationPolicy: Owner
  data:
    - secretKey: ConnectionStrings__DefaultConnection
      remoteRef:
        key: __DB_ITEM_ID__
        property: connection-string

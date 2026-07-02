apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-db-config
  namespace: tenant-__TENANT_ID__
  labels:
    app: tenant-db
    tenant.navosec.io/id: __TENANT_ID__
data:
  POSTGRES_DB: navosec_tenant
  POSTGRES_USER: navosec_tenant
  PGDATA: /var/lib/postgresql/data/pgdata
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tenant-db
  namespace: tenant-__TENANT_ID__
  labels:
    app: tenant-db
    tenant.navosec.io/id: __TENANT_ID__
spec:
  serviceName: tenant-db
  replicas: 1
  selector:
    matchLabels:
      app: tenant-db
  template:
    metadata:
      labels:
        app: tenant-db
        tenant.navosec.io/id: __TENANT_ID__
    spec:
      automountServiceAccountToken: false
      # DB laeuft auf dem dedizierten Tenant-Node (gleiche Isolation wie App).
      nodeSelector:
        tenant.navosec.io/dedicated: __TENANT_ID__
      tolerations:
        - key: tenant.navosec.io/dedicated
          operator: Equal
          value: __TENANT_ID__
          effect: NoSchedule
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - configMapRef:
                name: tenant-db-config
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: tenant-db-credentials
                  key: postgres-password
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          startupProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            periodSeconds: 5
            failureThreshold: 30
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            periodSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: __TENANT_DB_STORAGE__
---
apiVersion: v1
kind: Service
metadata:
  name: tenant-db
  namespace: tenant-__TENANT_ID__
  labels:
    app: tenant-db
    tenant.navosec.io/id: __TENANT_ID__
spec:
  # Headless: tenant-db.tenant-__TENANT_ID__.svc.cluster.local:5432
  clusterIP: None
  selector:
    app: tenant-db
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres

apiVersion: v1
kind: ConfigMap
metadata:
  name: navosec-app-config
  namespace: tenant-__TENANT_ID__
  labels:
    app: navosec-app
    tenant.navosec.io/id: __TENANT_ID__
data:
  ASPNETCORE_URLS: http://+:8080
  ASPNETCORE_ENVIRONMENT: Production
  # Dedizierter Tenant-Workload: genau EIN Mandant pro Deployment.
  Tenant__Mode: DedicatedTenant
  Tenant__Id: __TENANT_ID__
  Health__EnableDetailed: "true"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: navosec-app
  namespace: tenant-__TENANT_ID__
  labels:
    app: navosec-app
    tenant.navosec.io/id: __TENANT_ID__
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: navosec-app
  namespace: tenant-__TENANT_ID__
  labels:
    app: navosec-app
    tenant.navosec.io/id: __TENANT_ID__
spec:
  replicas: __APP_REPLICAS__
  selector:
    matchLabels:
      app: navosec-app
  template:
    metadata:
      labels:
        app: navosec-app
        tenant.navosec.io/id: __TENANT_ID__
    spec:
      serviceAccountName: navosec-app
      automountServiceAccountToken: false
      # Node-Isolation: dieser Tenant darf nur auf seinen dedizierten Node(s)
      # laufen. Die Node traegt Label + Taint tenant.navosec.io/dedicated=<id>.
      nodeSelector:
        tenant.navosec.io/dedicated: __TENANT_ID__
      tolerations:
        - key: tenant.navosec.io/dedicated
          operator: Equal
          value: __TENANT_ID__
          effect: NoSchedule
      securityContext:
        runAsNonRoot: true
        fsGroup: 2000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: __APP_IMAGE__
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: navosec-app-config
            - secretRef:
                # wird von db-externalsecret.yaml.tpl aus Vaultwarden befuellt
                name: tenant-db-secret
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          startupProbe:
            httpGet:
              path: /health/startup
              port: http
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: navosec-app
  namespace: tenant-__TENANT_ID__
  labels:
    app: navosec-app
    tenant.navosec.io/id: __TENANT_ID__
spec:
  selector:
    app: navosec-app
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: navosec-app
  namespace: tenant-__TENANT_ID__
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  labels:
    app: navosec-app
    tenant.navosec.io/id: __TENANT_ID__
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - __TENANT_ID__.__DOMAIN__
      secretName: tenant-__TENANT_ID__-tls
  rules:
    - host: __TENANT_ID__.__DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: navosec-app
                port:
                  number: 80

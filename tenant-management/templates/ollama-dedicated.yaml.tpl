apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: tenant-__TENANT_ID__
  labels:
    app: ollama
    tenant.navosec.io/id: __TENANT_ID__
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: __OLLAMA_STORAGE__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ollama
  namespace: tenant-__TENANT_ID__
  labels:
    app: ollama
    tenant.navosec.io/id: __TENANT_ID__
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: tenant-__TENANT_ID__
  labels:
    app: ollama
    tenant.navosec.io/id: __TENANT_ID__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
        tenant.navosec.io/id: __TENANT_ID__
    spec:
      serviceAccountName: ollama
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      # Verpflichtend dediziert: laeuft auf dem dedizierten Tenant-Node.
      # Ist dieser ein GPU-Node, wird zusaetzlich der gpu-Taint toleriert.
      nodeSelector:
        tenant.navosec.io/dedicated: __TENANT_ID__
      tolerations:
        - key: tenant.navosec.io/dedicated
          operator: Equal
          value: __TENANT_ID__
          effect: NoSchedule
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: ollama
          image: ollama/ollama:0.9.6
          env:
            - name: OLLAMA_HOST
              value: 0.0.0.0:11434
          ports:
            - name: http
              containerPort: 11434
          resources:
            requests:
              cpu: "__OLLAMA_REQ_CPU__"
              memory: __OLLAMA_REQ_MEM__
              nvidia.com/gpu: "__OLLAMA_REQ_GPU__"
            limits:
              cpu: "__OLLAMA_LIM_CPU__"
              memory: __OLLAMA_LIM_MEM__
              nvidia.com/gpu: "__OLLAMA_LIM_GPU__"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: tenant-__TENANT_ID__
  labels:
    app: ollama
    tenant.navosec.io/id: __TENANT_ID__
spec:
  selector:
    app: ollama
  ports:
    - name: http
      port: 11434
      targetPort: http
  type: ClusterIP

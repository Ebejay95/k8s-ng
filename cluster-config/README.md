# cluster-config — Control-Plane-Bootstrap (NICHT über GitOps/Kustomize)

Diese Dateien konfigurieren die **Control Plane** bzw. die **Nodes** und werden
bewusst **nicht** in `base/kustomization.yaml` referenziert. Sie werden beim
Cluster-Bootstrap (kubeadm/Terraform/Node-Provisioning) angewendet und liegen
hier nur versioniert und annotiert vor (APP.4.4.A8).

| Datei | BSI | Zweck |
|-------|-----|-------|
| `encryption-config.yaml` | A20 | Verschlüsselung der etcd-Daten at rest (EncryptionConfiguration des kube-apiservers) |
| `audit-policy.yaml` | A3/A12 | API-Server Audit-Policy (Protokollierung aller Aktionen, keine anonymen Admin-Aktionen) |
| `etcd-snapshot-cronjob.yaml` | A5 | Regelmäßige etcd-Snapshots auf den Control-Plane-Nodes |
| `kube-bench-cronjob.yaml` | A13 | Automatisiertes CIS-Kubernetes-Benchmark-Audit der Nodes |
| `encrypted-storageclass.yaml` | A20 | Verschlüsselte PersistentVolumes (LUKS via CSI) |

## Anwendung

- `encryption-config.yaml` + `audit-policy.yaml`: auf den Control-Plane-Nodes
  unter `/etc/kubernetes/` ablegen und den `kube-apiserver` mit
  `--encryption-provider-config` bzw. `--audit-policy-file` starten.
- `etcd-snapshot-cronjob.yaml` / `kube-bench-cronjob.yaml`: benötigen
  Host-Zugriff und laufen im Namespace `kube-system` (außerhalb der
  `restricted`-Namespaces). Vor Anwendung Pfade/Images prüfen.

## Nicht per Manifest abbildbar

- **A17 Attestierung von Nodes**: TPM-/Secure-Boot-basierte Node-Attestierung
  (z. B. Keylime, SPIRE, Cloud-Provider Confidential Nodes). Muss im
  Node-Provisioning (Terraform/Image) verankert werden; die Control Plane
  nimmt nur erfolgreich attestierte Nodes auf. Siehe `docs/05-SECURITY-BASELINE.md`.

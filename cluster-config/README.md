# cluster-config — Control-Plane-Bootstrap (NICHT über GitOps/Kustomize)

Diese Dateien konfigurieren die **Control Plane** bzw. die **Nodes** und werden
bewusst **nicht** in `base/kustomization.yaml` referenziert. Sie werden beim
Cluster-Bootstrap (Terraform/Node-Provisioning) angewendet und liegen hier nur
versioniert und annotiert vor (APP.4.4.A8).

> **Wichtig — Talos ist die autoritative Quelle für Verschlüsselung & Audit.**
> Auf einem Talos-Cluster werden `encryption-provider-config` und die
> Audit-Policy **inline** in [../talos/patches/controlplane.yaml](../talos/patches/controlplane.yaml)
> gepflegt (Talos verlangt sie in der Machine-Config). Es gibt daher hier
> **keine** separaten `encryption-config.yaml`/`audit-policy.yaml` mehr, um
> Doppelpflege/Drift zu vermeiden. Nur bei einem Nicht-Talos-Cluster
> (z. B. kubeadm) müssten diese als eigene Dateien wieder ergänzt werden.

| Datei | BSI | Zweck |
|-------|-----|-------|
| `etcd-snapshot-cronjob.yaml` | A5 | Regelmäßige etcd-Snapshots. **Auf Talos** stattdessen `talosctl etcd snapshot` (nativ) bevorzugen. |
| `kube-bench-cronjob.yaml` | A13 | Automatisiertes CIS-Kubernetes-Benchmark-Audit der Nodes |
| `encrypted-storageclass.yaml` | A20 | Verschlüsselte PersistentVolumes (LUKS via Hetzner CSI) — beim Bootstrap auf dem Cluster anwenden |

## Anwendung

- **Verschlüsselung/Audit:** siehe [../talos/patches/controlplane.yaml](../talos/patches/controlplane.yaml).
- `etcd-snapshot-cronjob.yaml`: auf Talos durch `talosctl etcd snapshot` (per
  Cron/CI) ersetzbar; die CronJob-Variante benötigt Host-/etcd-Zugriff.
- `kube-bench-cronjob.yaml`: benötigt Host-Zugriff, läuft in `kube-system`
  (außerhalb der `restricted`-Namespaces). Vor Anwendung Pfade/Images prüfen.
- `encrypted-storageclass.yaml`: einmalig auf dem Hetzner-Cluster anwenden
  (nicht auf Docker Desktop — dort fehlt der Hetzner-CSI).

## Nicht per Manifest abbildbar

- **A17 Attestierung von Nodes**: TPM-/Secure-Boot-basierte Node-Attestierung
  (z. B. Keylime, SPIRE, Cloud-Provider Confidential Nodes). Muss im
  Node-Provisioning (Terraform/Image) verankert werden; die Control Plane
  nimmt nur erfolgreich attestierte Nodes auf. Siehe `docs/05-SECURITY-BASELINE.md`.

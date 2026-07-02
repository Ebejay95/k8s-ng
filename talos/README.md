# Talos Linux – gehärtete Node-Ebene

Talos ist ein minimales, immutables, API-verwaltetes Betriebssystem für
Kubernetes (kein SSH, keine Shell, read-only rootfs). Damit heben wir die
Härtung von der reinen Kubernetes-Ebene auf die **Node-Ebene** und aktivieren
die bisher nur in `../cluster-config/` abgelegten Configs **tatsächlich**.

## Was diese Patches bewirken

`patches/controlplane.yaml`:
- **APP.4.4.A20 (at rest):** `--encryption-provider-config` wird gesetzt und die
  Provider-Datei nach `/etc/kubernetes/encryption-config.yaml` geschrieben →
  Secrets/ConfigMaps/PVCs/ExternalSecrets in etcd verschlüsselt.
- **APP.4.4.A3 / A12:** Audit-Policy inline → Talos setzt `--audit-policy-file`
  und `--audit-log-path` automatisch; zusätzlich `anonymous-auth=false`.
- **APP.4.4.A20 (Disk):** System- und Ephemeral-Partition mit **LUKS2**
  verschlüsselt.
- **CNI:** Talos-CNI aus (`none`) + kube-proxy aus → Cilium übernimmt (siehe
  `../cni/`).

`patches/worker.yaml`:
- LUKS2-Disk-Encryption, gehärtete Kubelet-Flags.

## TPM / vTPM – ehrlicher Hinweis

- **Hetzner Dedicated / Bare-Metal** mit physischem TPM 2.0: `tpm: {}` als
  LUKS-Key → Measured Boot, Schlüssel im TPM versiegelt. Das ist die
  Voraussetzung für APP.4.4.A17-nahe Hardware-Attestierung.
- **Hetzner Cloud (VMs): KEIN vTPM verfügbar.** Dort den `tpm: {}`-Block durch
  `nodeID: {}` (oder externes `kms:`) ersetzen. Disk-Encryption ist damit aktiv,
  aber ohne Hardware-Vertrauensanker. Die Patches enthalten den Fallback als
  Kommentar.

## Workflow

```bash
# 1) Basis-Config erzeugen
talosctl gen config navosec https://<API-ENDPOINT>:6443 \
  --output-dir _out

# 2) Patches anwenden
talosctl machineconfig patch _out/controlplane.yaml \
  --patch @patches/controlplane.yaml -o _out/controlplane.yaml
talosctl machineconfig patch _out/worker.yaml \
  --patch @patches/worker.yaml -o _out/worker.yaml

# 3) VOR dem Ausrollen: Platzhalter ersetzen!
#    - CHANGE_ME_BASE64_32_BYTE_KEY  ->  head -c 32 /dev/urandom | base64
#    - hcloud: tpm-Blöcke -> nodeID
sed -i '' "s#CHANGE_ME_BASE64_32_BYTE_KEY#$(head -c 32 /dev/urandom | base64)#" \
  _out/controlplane.yaml

# 4) Auf die Nodes anwenden
talosctl apply-config --insecure -n <NODE-IP> --file _out/controlplane.yaml
# ... weitere Control-Plane- und Worker-Nodes ...

# 5) Cluster bootstrappen (einmalig auf EINEM Control-Plane-Node)
talosctl bootstrap -n <CP-NODE-IP> -e <CP-NODE-IP>

# 6) kubeconfig ziehen
talosctl kubeconfig -n <CP-NODE-IP> -e <CP-NODE-IP>

# 7) CNI installieren (Talos startet ohne CNI -> Nodes NotReady bis dahin)
../cni/install.sh
```

## Talos auf Hetzner Cloud

Hetzner bietet kein Talos-Image out of the box. Übliche Wege:
1. **Snapshot** aus dem offiziellen Talos-`hcloud`-Image erzeugen (z. B. via
   `hcloud-upload-image` oder Packer) und als `image`/`snapshot` in Terraform
   (`../terraform/hetzner/`) referenzieren.
2. Community-Tooling `hcloud-talos` für einen vollautomatischen Bootstrap.

Die vorhandenen Server-Ressourcen in `../terraform/hetzner/` müssen dann auf das
Talos-Snapshot-Image umgestellt und `user_data` durch die generierte
Machine-Config ersetzt werden.

## Verifikation nach dem Rollout

```bash
# etcd-Verschlüsselung greift?
kubectl -n kube-system get secret -o name | head -1
# Audit-Log läuft?
talosctl -n <CP-NODE-IP> logs kubelet | grep -i audit
# Disk-Encryption aktiv?
talosctl -n <NODE-IP> get systemdiskencryption
```

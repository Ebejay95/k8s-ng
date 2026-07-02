# CNI – Cilium

Cilium ist das Container Network Interface (CNI) dieser Plattform. Es schließt
mehrere BSI-Lücken auf einmal:

| Lücke | Ohne CNI (z. B. Docker Desktop) | Mit Cilium |
| --- | --- | --- |
| **APP.4.4.A7** NetworkPolicies | werden **nicht** durchgesetzt | erzwungen |
| **APP.4.4.A20** in-transit-Verschlüsselung | Node-zu-Node im Klartext | WireGuard-verschlüsselt |
| kube-proxy | zusätzlicher Angriffsvektor | ersetzt (`kubeProxyReplacement`) |
| Netzwerk-Sichtbarkeit | keine | Hubble (Flows/Metriken/UI) |

## Warum Bootstrap statt Kustomize/ArgoCD?

Das CNI muss laufen, **bevor** irgendein anderer Pod Netzwerk bekommt. Daher
wird Cilium **einmalig per Helm** installiert (`install.sh`). Erst danach
übernehmen Kustomize/ArgoCD die Anwendungs-Workloads.

## Installation

```bash
# Kontext auf den Zielcluster setzen, dann:
./cni/install.sh
# optional andere Version:
CILIUM_VERSION=1.16.5 ./cni/install.sh
```

Bei **Talos** ist das eingebaute CNI deaktiviert (`cluster.network.cni.name: none`)
und kube-proxy abgeschaltet (`cluster.proxy.disabled: true`) – siehe
`../talos/patches/controlplane.yaml`. Die Values in `cilium-values.yaml` sind
bereits auf Talos (KubePrism `localhost:7445`) und Hetzner Cloud (VXLAN-Tunnel)
abgestimmt.

## Lokal (Docker Desktop) testen

Cilium **kann** auf Docker Desktop installiert werden, um NetworkPolicy-
Enforcement lokal zu prüfen. Dann in `cilium-values.yaml` `k8sServiceHost`/
`k8sServicePort` und `kubeProxyReplacement` an die lokale Umgebung anpassen
(Docker Desktop nutzt kube-proxy, also `kubeProxyReplacement: false` und den
API-Server-Host `kubernetes.default`). Ohne Anpassung sind die Werte auf Talos
ausgelegt.

## Verifikation

```bash
cilium status --wait                 # benötigt cilium-CLI
kubectl -n kube-system get pods -l k8s-app=cilium
cilium connectivity test             # optional, umfangreich
```

WireGuard prüfen:

```bash
kubectl -n kube-system exec ds/cilium -- cilium encrypt status
```

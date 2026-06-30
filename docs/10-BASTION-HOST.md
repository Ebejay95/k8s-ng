# 10-BASTION-HOST.md – Jumphost für Administrative Zugriffe

## Architektur

Private Cluster: Nur Bastion hat externe IP. Alles andere Zugriff über Bastion:

```
Internet
  │
  ├─ Admin SSH → Bastion (52.1.2.3:22)
  │   └─ Bastion SSH → Control Plane Node (10.0.1.10:22)
  │       └─ Bastion kubectl → API Server (10.0.1.10:6443)
  │
  └─ Admin HTTPS → Grafana via Bastion Tunnel (Socks5 Proxy)
      └─ Tunnel to http://grafana.local:3000
```

---

## 1. Bastion VM (Hetzner Terraform)

```hcl
# terraform/hetzner/bastion.tf

resource "hcloud_server" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  name              = "${local.cluster_name}-bastion"
  image             = "ubuntu-24.04"
  server_type       = "cx21"  # 2 vCPU, 4 GB RAM
  location          = var.location
  ssh_keys          = [hcloud_ssh_key.default.id]
  delete_protection = var.environment == "prod" ? true : false

  labels = merge(
    local.common_labels,
    { "role" = "bastion" }
  )
}

# Bastion hat PUBLIC IP
resource "hcloud_floating_ip" "bastion" {
  count        = var.enable_bastion ? 1 : 0
  name         = "${local.cluster_name}-bastion-ip"
  type         = "ipv4"
  location     = var.location
  description  = "Bastion public IP"

  labels = local.common_labels
}

resource "hcloud_floating_ip_assignment" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  floating_ip_id    = hcloud_floating_ip.bastion[0].id
  server_id         = hcloud_server.bastion[0].id
}

# Firewall nur für Bastion SSH
resource "hcloud_firewall_rule" "bastion_ssh" {
  count             = var.enable_bastion ? 1 : 0
  firewall_id       = hcloud_firewall.kubernetes.id
  direction         = "in"
  protocol          = "tcp"
  port              = "22"
  source_ips        = var.bastion_allowed_ips  # z.B. ["203.0.113.0/24"]  Deine Office IP
}

output "bastion_public_ip" {
  value = try(hcloud_floating_ip.bastion[0].ip_address, null)
}
```

---

## 2. Bastion Setup (Cloud-Init)

```bash
#!/bin/bash
# bastion/cloud-init.sh

set -euo pipefail

# Updates
apt-get update && apt-get upgrade -y

# SSH Hardening
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# Tools installieren
apt-get install -y \
  curl \
  wget \
  git \
  jq \
  postgresql-client \
  mysql-client \
  kubectl \
  helm \
  kubeseal \
  cosign

# kubectl Config (vom Cluster kopieren)
mkdir -p ~/.kube
# Später: kubectl config wird kopiert von CI/CD oder Admin

# Log für Audit
echo "Bastion initialized at $(date)" > /var/log/bastion-init.log

# Monitoring Agent (optional)
# curl -sSfL https://monitoring.meinedomain.de/agent-install.sh | bash
```

---

## 3. Bastion Access Control

```bash
# bastion/authorized_keys Rotation

#!/bin/bash
# ~/.ssh/authorized_keys für Bastion
# Nur spezifische Admins dürfen SSH zugang

ssh-rsa AAAAB3NzaC1yc2E... admin1@meinedomain.de
ssh-rsa AAAAB3NzaC1yc2E... admin2@meinedomain.de
ssh-rsa AAAAB3NzaC1yc2E... support-lead@meinedomain.de

# Abgelaufene Keys entfernen (manuell oder script)
```

---

## 4. Bastion Tunnel Setup

```bash
#!/bin/bash
# bastion/setup-tunnels.sh

# Setup SSH Config für lokale Tunnels

cat > ~/.ssh/config <<EOF
Host bastion
  HostName ${BASTION_IP}
  User ubuntu
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null

# Durchleitung zur Cluster API
Host cluster-api
  HostName 10.0.1.10
  User talos
  ProxyCommand ssh -W %h:%p bastion
  StrictHostKeyChecking no

# SOCKS5 Proxy für Web-UI Zugriff
Host bastion-proxy
  HostName ${BASTION_IP}
  User ubuntu
  DynamicForward 9050
EOF

# Verbindung testen
ssh -fN bastion-proxy  # SOCKS5 läuft auf localhost:9050
```

---

## 5. kubectl Zugang via Bastion

```bash
#!/bin/bash
# bastion/kubeconfig-setup.sh

# Kubeconfig konfigurieren
kubectl config set-cluster navosec-prod \
  --server=https://10.0.1.10:6443 \
  --insecure-skip-tls-verify=true

kubectl config set-context bastion-admin \
  --cluster=navosec-prod \
  --user=bastion-admin

# Proxy: kubectl Traffic über Bastion SSH
export BASTION_HOST=52.1.2.3
export CLUSTER_API=10.0.1.10

# Tunnel starten
ssh -fNL 6443:${CLUSTER_API}:6443 ubuntu@${BASTION_HOST}

# Lokal zugreifen
kubectl --kubeconfig=./kubeconfig get pods
```

---

## 6. Admin Panel via Bastion

```bash
#!/bin/bash
# bastion/access-admin-panel.sh

# Argo CD über Bastion SOCKS5 zugänglich

# 1. Tunnel starten
ssh -fNL 3000:grafana.navosec-prod.svc.cluster.local:3000 \
    -L 8080:argo-cd-server.argocd.svc.cluster.local:443 \
    ubuntu@${BASTION_IP}

# 2. Browser öffnen
echo "🔓 Argo CD: https://localhost:8080"
echo "📊 Grafana: http://localhost:3000"
open https://localhost:8080
```

---

## 7. Audit & Logging (Bastion)

```bash
# bastion/audit-config.sh

# Alle SSH Zugriffe loggen
echo 'session optional pam_exec.so /usr/local/bin/log-ssh-session.sh' \
  >> /etc/pam.d/sshd

# Script
cat > /usr/local/bin/log-ssh-session.sh <<'SCRIPT'
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') SSH Access: $PAM_USER from $PAM_RHOST" \
  >> /var/log/bastion-audit.log
SCRIPT
chmod +x /usr/local/bin/log-ssh-session.sh
```

---

## 8. Bastion Monitoring

```yaml
# bastion/prometheus-config.yaml

# Auf Bastion läuft optional Prometheus Agent
scrape_configs:
  - job_name: bastion
    static_configs:
      - targets: ['localhost:9100']  # Node Exporter

alert_rules:
  - alert: BastionSSHFailures
    expr: increase(node_systemd_unit_state{name="ssh.service",state="failed"}[5m]) > 10
    annotations:
      summary: "Multiple SSH failures on Bastion"
```

---

## 9. Bastion für CI/CD

```bash
# CI/CD kann auch via Bastion auf Cluster zugreifen
# GitHub Actions Secret:

BASTION_SSH_KEY: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...

# In CI/CD:
ssh -i ~/.ssh/bastion_key \
    -o ProxyCommand="ssh -i ~/.ssh/bastion_key -W %h:%p ubuntu@${BASTION_IP}" \
    ubuntu@${CONTROL_PLANE_IP} \
    "kubectl apply -f deployment.yaml"
```

---

## Checkliste

- [ ] Bastion VM deployed (Hetzner)
- [ ] SSH Hardening durchgeführt
- [ ] Authorized Keys konfiguriert (nur spezifische Admins)
- [ ] Firewall: SSH nur vom Office/Admin IP
- [ ] kubectl Zugang via Bastion
- [ ] SOCKS5 Proxy für Web-UI
- [ ] Argo CD/Grafana über Tunnel zugänglich
- [ ] Audit Logging aktiviert
- [ ] Monitoring auf Bastion
- [ ] SSH Keys rotiert (monatlich)

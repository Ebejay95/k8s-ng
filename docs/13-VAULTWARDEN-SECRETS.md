# 13-VAULTWARDEN-SECRETS.md – Secrets aus Vaultwarden (einfach erklaert)

## Kurzantwort

Ja, das geht. Fuer Vaultwarden (Password Manager) ist der robuste Weg:

1. External Secrets Operator (ESO) im Cluster
2. Bitwarden CLI Pod als interner Adapter (Webhook-Ziel)
3. ClusterSecretStore + ExternalSecret
4. App bekommt ihr Kubernetes Secret automatisch

Du speicherst also Secrets zentral in Vaultwarden, und Kubernetes zieht sie regelmaessig.

---

## Warum nicht direkt aus der App?

- App direkt gegen Vaultwarden koppeln ist unnoetig komplex.
- Mit ESO bleibt die App unveraendert und liest weiterhin nur Kubernetes Secret.
- Rotation wird einfacher, weil ESO automatisch aktualisiert.

---

## Was bedeutet dein "public + pre shared key"?

- **Public URL** von Vaultwarden ist normal und noetig (bitwarden-cli muss dahin).
- **Pre Shared Key** ist fuer Vaultwarden-Password-Manager nicht der Standardbegriff.
- Standard fuer bw-cli ist meist:
  - `BW_CLIENTID` + `BW_CLIENTSECRET` + `BW_PASSWORD` (empfohlen)
  - oder `BW_USERNAME` + `BW_PASSWORD`

Wenn dein "PSK" ein eigener API-Gateway-Header ist, kann man das zusaetzlich davorhaengen. Die aktuelle Basis hier nutzt den offiziellen bw-cli Weg.

---

## Dateien in diesem Repo

- `external-secrets/` enthaelt Vaultwarden-Bridge + SecretStores
- `app/21-externalsecret-navosec-app.yaml` erstellt `navosec-app-secret` automatisch
- `app/20-secret-template.yaml` ist optionaler Legacy-Fallback und wird im Standard-Flow nicht mehr verwendet

---

## Setup hier (lokal/cluster)

### 1) External Secrets Operator installieren

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

### 2) Vaultwarden Zugangsdaten eintragen

Datei bearbeiten:
- `external-secrets/10-bitwarden-cli-credentials-template.yaml`

Setzen:
- `BW_HOST`
- `BW_CLIENTID`
- `BW_CLIENTSECRET`
- `BW_PASSWORD`

### 3) Item in Vaultwarden anlegen

Ein Item mit Custom Fields, z.B.:
- `connection-string`
- `redis-connection`
- `google-client-id`
- `google-client-secret`

Dann Item-ID kopieren.

### 4) ExternalSecret auf Item-ID zeigen lassen

Datei:
- `app/21-externalsecret-navosec-app.yaml`

`CHANGE_ME_ITEM_ID_APP` ersetzen.

### 5) Alles deployen

```bash
kubectl apply -k k8s-ng
```

### 6) Pruefen

```bash
kubectl get pods -n external-secrets
kubectl get clustersecretstore
kubectl get externalsecret -n navosec-prod
kubectl get secret navosec-app-secret -n navosec-prod -o yaml
```

---

## Setup auf prod

## 1) Unterschied zu "hier"

- Gleiche YAML-Logik
- Andere echte Zugangsdaten
- Strengere NetworkPolicies
- Argo CD deployt aus Git

## 2) Prod-Hardening (wichtig)

- `external-secrets/13-bitwarden-cli-networkpolicy.yaml` aktiv lassen
- Nur ESO darf auf `bitwarden-cli` zugreifen
- Secret mit Credentials nicht im Klartext in Git committen
- Zugangsdaten als einmaligen Bootstrap per `kubectl create secret` setzen
- Rotation planen (Client Secret / Password)

## 3) Bootstrap ohne Klartext in Git

Statt Datei zu committen:

```bash
kubectl create secret generic bitwarden-cli \
  -n external-secrets \
  --from-literal=BW_HOST='https://vault.example.com' \
  --from-literal=BW_CLIENTID='...' \
  --from-literal=BW_CLIENTSECRET='...' \
  --from-literal=BW_PASSWORD='...'
```

Dann in Git die Template-Datei nur als Beispiel behalten.

## 4) Argo CD Reihenfolge

Empfohlen:
1. external-secrets operator
2. `external-secrets/` (bw-cli + stores)
3. `app/` (ExternalSecret erstellt App-Secret)
4. App Deployment nutzt Secret

---

## Troubleshooting fuer Dummies

### ExternalSecret bleibt rot

- Item-ID falsch
- Feldname (`property`) falsch
- bw-cli kann Vaultwarden nicht erreichen

Checks:

```bash
kubectl describe externalsecret navosec-app-secret -n navosec-prod
kubectl logs deploy/bitwarden-cli -n external-secrets
kubectl get secret bitwarden-cli -n external-secrets -o yaml
```

### App startet nicht wegen Secret

- Secret fehlt oder Key-Name stimmt nicht

Check:

```bash
kubectl get secret navosec-app-secret -n navosec-prod -o jsonpath='{.data}'
```

---

## Sicherheits-Hinweis

Wenn du wirklich einen PSK-geschuetzten eigenen Secret-Endpoint hast, kann ich dir im naechsten Schritt eine zweite Variante mit `SecretStore.provider.webhook.headers` und `X-Pre-Shared-Key` bauen.

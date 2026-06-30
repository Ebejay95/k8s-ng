# 09-CI-CD-PIPELINE.md – Trivy, Image Scanning, Build & Push, Deployment

## Pipeline Stages

```
1. Code Push
   ↓
2. Build (Kaniko / Docker)
   ↓
3. Scan (Trivy)
   ├─ Critical Vuln? → FAIL
   └─ OK? → Continue
   ↓
4. Sign Image (Cosign)
   ↓
5. Push to Registry (ghcr.io)
   ↓
6. Update Git (Kustomize/Helm)
   ↓
7. Argo CD Auto-Sync
   ↓
8. Deploy to Cluster
```

---

## 1. GitHub Actions Workflow

```yaml
# .github/workflows/build-and-deploy.yaml

name: Build & Deploy

on:
  push:
    branches:
      - main
    paths:
      - 'src/**'
      - 'Dockerfile'
      - '.github/workflows/build-and-deploy.yaml'

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write  # Für Cosign signing

    steps:
      # 1. Checkout Code
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Für Version Tags

      # 2. Set Image Tag
      - name: Set Image Tag
        id: meta
        run: |
          VERSION=$(git describe --tags --always --dirty)
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
          echo "image=ghcr.io/${{ github.repository }}/navosec-web:${VERSION}" >> $GITHUB_OUTPUT

      # 3. Build mit Kaniko (no Docker daemon needed)
      - name: Build Image with Kaniko
        uses: gcr.io/kaniko-project/executor@latest
        with:
          context: .
          dockerfile: Dockerfile
          destination: ${{ steps.meta.outputs.image }}
          registry-mirror: mirror.gcr.io
          cache: true
          cache-repo: ghcr.io/${{ github.repository }}/cache

      # 4. Scan mit Trivy
      - name: Scan Image with Trivy
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ steps.meta.outputs.image }}
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'

      # 5. Upload Trivy Results
      - name: Upload Trivy Results
        uses: github/codeql-action/upload-sarif@v2
        with:
          sarif_file: 'trivy-results.sarif'

      # 6. Fail if Critical Vulns
      - name: Check Trivy Results
        run: |
          if grep -q '"level": "CRITICAL"' trivy-results.sarif; then
            echo "❌ Critical vulnerabilities found"
            exit 1
          fi

      # 7. Sign Image mit Cosign
      - name: Sign Image with Cosign
        run: |
          cosign sign --key env://COSIGN_KEY \
            ${{ steps.meta.outputs.image }}
        env:
          COSIGN_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}

      # 8. Update Helm values für Argo CD (GitOps)
      - name: Update Helm Values
        run: |
          cd k8s-ng/app/helm
          sed -i "s|image:.*|image: ${{ steps.meta.outputs.image }}|" values-prod.yaml
          git config user.name "CI Bot"
          git config user.email "ci@meinedomain.de"
          git add values-prod.yaml
          git commit -m "🔄 Update image to ${{ steps.meta.outputs.version }}"
          git push origin main
```

---

## 2. Trivy Scanning (lokal)

```bash
# cicd/scan.sh

#!/bin/bash
set -euo pipefail

IMAGE=${1:-ghcr.io/yourorg/navosec-web:latest}

echo "🔍 Scanning $IMAGE with Trivy..."

trivy image \
  --severity CRITICAL,HIGH \
  --exit-code 0 \
  --format json \
  --output scan-report.json \
  "$IMAGE"

# Parse Results
CRITICAL=$(jq '[.Results[] | select(.Severity=="CRITICAL")] | length' scan-report.json)
HIGH=$(jq '[.Results[] | select(.Severity=="HIGH")] | length' scan-report.json)

echo ""
echo "📊 Scan Results:"
echo "  Critical: $CRITICAL"
echo "  High: $HIGH"
echo ""

if [ "$CRITICAL" -gt 0 ]; then
  echo "❌ Critical vulnerabilities found. Aborting deployment."
  exit 1
fi

echo "✅ Scan passed"
```

---

## 3. Container Registry (GHCR mit Retention)

```yaml
# cicd/registry-config.yaml

# GitHub Container Registry (GHCR) mit Retention Policy
# Via GitHub Actions Secrets:
# - REGISTRY_USERNAME: (dein GitHub Username)
# - REGISTRY_TOKEN: (Personal Access Token mit write:packages)

# Login
docker login ghcr.io -u $REGISTRY_USERNAME -p $REGISTRY_TOKEN

# Tag & Push
docker tag navosec-web:latest ghcr.io/yourorg/navosec-web:v1.2.3
docker push ghcr.io/yourorg/navosec-web:v1.2.3
```

---

## 4. Image Signing (Cosign)

```bash
# cicd/sign-image.sh

#!/bin/bash

IMAGE=$1
COSIGN_KEY_FILE=${COSIGN_KEY_FILE:-}

if [ -z "$IMAGE" ]; then
  echo "Usage: $0 <image>"
  exit 1
fi

# Cosign installieren (falls nicht vorhanden)
if ! command -v cosign &> /dev/null; then
  curl -sSfL https://github.com/sigstore/cosign/releases/download/v2.0.0/cosign-linux-amd64 \
    -o /usr/local/bin/cosign
  chmod +x /usr/local/bin/cosign
fi

# Sign
echo "🔐 Signing image $IMAGE..."
cosign sign --key env://COSIGN_KEY "$IMAGE"

# Verify
echo "✅ Verifying signature..."
cosign verify --key env://COSIGN_PUB_KEY "$IMAGE"
```

---

## 5. SBoM (Software Bill of Materials)

```bash
# cicd/generate-sbom.sh

#!/bin/bash

IMAGE=$1

# Generate SBOM mit Syft
syft "$IMAGE" -o spdx-json > sbom.json

# Upload zu Dependency Track (optional)
curl -X POST https://dependency-track.meinedomain.de/api/v1/bom \
  -H "X-API-Key: $DEPENDENCY_TRACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d @sbom.json
```

---

## 6. Policy as Code (OPA/Rego)

```rego
# cicd/policy.rego - Image Scanning Policies

package main

# Keine Images von untrusted Registry
deny[msg] {
    image := input.image
    not startswith(image, "ghcr.io/yourorg/")
    msg := sprintf("Image from untrusted registry: %s", [image])
}

# Keine Images ohne Tag (latest)
deny[msg] {
    image := input.image
    not contains(image, ":")
    msg := sprintf("Image must have explicit tag: %s", [image])
}

# Kein "latest" Tag in Production
deny[msg] {
    input.environment == "prod"
    image := input.image
    endswith(image, ":latest")
    msg := sprintf("Latest tag not allowed in production: %s", [image])
}

# Whitelist erlaubte Tags
allow[msg] {
    image := input.image
    regex.match(".*:v[0-9]+\\.[0-9]+\\.[0-9]+", image)
    msg := sprintf("✅ Image tag is valid: %s", [image])
}
```

---

## 7. Deployment Stage (nach erfolgreicher CI)

```yaml
# cicd/deploy-manifest.yaml

# Über Kustomize oder Helm (in Git)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

images:
  - name: navosec-web
    newName: ghcr.io/yourorg/navosec-web
    newTag: v1.2.3  # Wird von CI aktualisiert

patchesStrategicMerge:
  - deployment-patch.yaml
```

```bash
# cicd/update-deployment.sh

#!/bin/bash

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  exit 1
fi

# Update Kustomization
cd k8s-ng
kustomize edit set image \
  navosec-web=ghcr.io/yourorg/navosec-web:$VERSION

# Commit & Push (Argo CD synct automatisch)
git add kustomization.yaml
git commit -m "🚀 Update app version to $VERSION"
git push origin main
```

---

## 8. CI/CD Secrets Management

```bash
# GitHub Actions Secrets (Web UI oder CLI)
gh secret set REGISTRY_TOKEN --body "ghp_xxxx"
gh secret set COSIGN_PRIVATE_KEY --body "-----BEGIN EC PRIVATE KEY-----..."
gh secret set TRIVY_SEVERITY --body "CRITICAL,HIGH"
```

---

## 9. Checkliste

- [ ] GitHub Actions Workflow konfiguriert
- [ ] Trivy Scanning für alle Images
- [ ] Image Signing mit Cosign
- [ ] Registry Policy: Nur ghcr.io erlaubt
- [ ] SBoM Generierung
- [ ] Deployment via GitOps (Argo CD)
- [ ] Secrets sind verschlüsselt
- [ ] Build Logs archiviert
- [ ] Alerts auf Scan-Fehler

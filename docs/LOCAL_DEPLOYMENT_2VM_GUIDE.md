# FIWARE Data Space Connector — Two-VM Deployment Guide
*Profiles: `-Plocal` and `-Plocal,gaia-x`*

---

## 1. Overview

This guide documents deploying the FIWARE Data Space Connector across two VMs, each with 16GB RAM, to overcome the 24GB minimum requirement for a single-VM deployment. The deployment uses K3s-in-Docker via the Maven plugin.

### 1.1 Architecture

| | VM1 — Consumer (.14) | VM2 — Provider (.16) |
|---|---|---|
| **IP** | 192.168.120.14 | 192.168.120.16 |
| **RAM / CPU** | 16GB / 8 cores | 16GB / 8 cores |
| **OS** | Ubuntu 25.04 | Ubuntu 25.04 |
| **Namespaces** | consumer, trust-anchor, infra, postgres-operator, mongo-operator | provider, mongo-operator, postgres-operator, cert-manager, infra |
| **Key services** | TIR, TIL, Consumer Keycloak, Traefik, Squid, GX Registry | APISIX, Scorpio, ODRL-PAP, Provider Keycloak, Contract-Mgmt, TM Forum API |
| **Maven pom** | pom-consumer.xml | pom-provider.xml |

> ⚠️ **CRITICAL:** Always load `br_netfilter` BEFORE running Maven on both VMs or CoreDNS UDP will fail and all pods will crash-loop.

---

## 2. Prerequisites

### 2.1 Install on Both VMs

Run the following on **both** VM1 (.14) and VM2 (.16):

```bash
# Docker
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER && newgrp docker

# Java 21, Maven, yq
sudo apt-get install -y openjdk-21-jdk maven yq wget

# Clone the FIWARE repo
git clone https://github.com/FIWARE/data-space-connector.git ~/data-space-connector

# Make br_netfilter load on boot (CRITICAL)
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
```

---

## 3. One-Time Configuration

These steps configure the repo on each VM for two-VM split operation. Run once after cloning.

### 3.1 VM1 (.14) — Consumer Side

#### 3.1.1 Update IP references in yaml files

```bash
cd ~/data-space-connector

# Point consumer and trust-anchor services to .14
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/consumer.yaml
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/trust-anchor.yaml

# Fix internal cluster DNS reference to point to .14 externally
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/consumer.yaml
```

For the **gaia-x profile** also run:

```bash
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/consumer-gaia-x.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/consumer-gaia-x.yaml
```

#### 3.1.2 Configure namespaces (keep only consumer-side)

```bash
cd ~/data-space-connector/k3s/namespaces/
rm -f provider.yaml wallet.yaml
# Keep: consumer.yaml, trust-anchor.yaml, infra.yaml,
#        mongo-operator.yaml, postgres-operator.yaml, cert-manager.yaml
```

#### 3.1.3 Create consumer-only pom

```bash
cd ~/data-space-connector
cp pom.xml pom-consumer.xml

# Remove provider template and copy steps
python3 << 'EOF'
import re
with open('pom-consumer.xml', 'r') as f:
    content = f.read()
content = re.sub(r'\s*<execution>\s*<id>template-dsc-provider</id>.*?</execution>', '', content, flags=re.DOTALL)
content = re.sub(r'\s*<execution>\s*<id>copy-resources-additional-provider</id>.*?</execution>', '', content, flags=re.DOTALL)
with open('pom-consumer.xml', 'w') as f:
    f.write(content)
print('Done')
EOF

# Reduce timeout from 1500s to 300s
sed -i 's/<timeout>1500<\/timeout>/<timeout>300<\/timeout>/g' pom-consumer.xml
```

---

### 3.2 VM2 (.16) — Provider Side

#### 3.2.1 Update IP references in yaml files

```bash
cd ~/data-space-connector

# Point all provider services to .16
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.16.nip.io/g' k3s/provider.yaml

# Fix tir references back to .14 (trust anchor lives on .14)
sed -i 's/tir\.192\.168\.120\.16\.nip\.io/tir.192.168.120.14.nip.io/g' k3s/provider.yaml

# Fix internal cluster DNS reference to point to .14 externally
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/provider.yaml
```

For the **gaia-x profile** also run:

```bash
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.16.nip.io/g' k3s/provider-gaia-x.yaml
sed -i 's/tir\.192\.168\.120\.16\.nip\.io/tir.192.168.120.14.nip.io/g' k3s/provider-gaia-x.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/provider-gaia-x.yaml
```

#### 3.2.2 Configure namespaces (keep only provider-side)

```bash
cd ~/data-space-connector/k3s/namespaces/
rm -f consumer.yaml trust-anchor.yaml wallet.yaml

# Recreate infra namespace (needed by traefik on .16)
cat > infra.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: infra
EOF

# Keep: provider.yaml, mongo-operator.yaml, postgres-operator.yaml,
#        cert-manager.yaml, infra.yaml
```

#### 3.2.3 Create provider-only pom

```bash
cd ~/data-space-connector
cp pom.xml pom-provider.xml

python3 << 'EOF'
import re
with open('pom-provider.xml', 'r') as f:
    content = f.read()
content = re.sub(r'\s*<execution>\s*<id>template-dsc-consumer</id>.*?</execution>', '', content, flags=re.DOTALL)
content = re.sub(r'\s*<execution>\s*<id>template-trust-anchor</id>.*?</execution>', '', content, flags=re.DOTALL)
content = re.sub(r'\s*<execution>\s*<id>copy-resources-additional-consumer</id>.*?</execution>', '', content, flags=re.DOTALL)
with open('pom-provider.xml', 'w') as f:
    f.write(content)
print('Done')
EOF

sed -i 's/<timeout>1500<\/timeout>/<timeout>300<\/timeout>/g' pom-provider.xml
```

---

## 4. Deployment Procedure

> ⚠️ Always start VM1 (.14) first and wait for TIR to be healthy before starting VM2 (.16).

### 4.1 Pre-deploy (BOTH VMs, every time)

```bash
# Load br_netfilter — MANDATORY before every deploy
sudo modprobe br_netfilter

# Wipe any previous deployment
docker ps -a | grep k3s | awk '{print $1}' | xargs -r docker rm -f
```

### 4.2 Deploy VM1 (.14) — Consumer + Trust Anchor

**For `-Plocal`:**
```bash
cd ~/data-space-connector
mvn clean deploy -Plocal -f pom-consumer.xml -Dhelm.version=3.14.0
```

**For `-Plocal,gaia-x`:**
```bash
cd ~/data-space-connector
mvn clean deploy -Plocal,gaia-x -f pom-consumer.xml -Dhelm.version=3.14.0
```

Wait for TIR to be healthy before starting VM2:

```bash
export KUBECONFIG=$(pwd)/target/k3s.yaml
# Wait until this returns the issuers JSON
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .
```

### 4.3 Deploy VM2 (.16) — Provider

**For `-Plocal`:**
```bash
cd ~/data-space-connector
mvn clean deploy -Plocal -f pom-provider.xml -Dhelm.version=3.14.0
```

**For `-Plocal,gaia-x`:**
```bash
cd ~/data-space-connector
mvn clean deploy -Plocal,gaia-x -f pom-provider.xml -Dhelm.version=3.14.0
```

---

## 5. Post-Deploy Recovery

Maven will time out waiting for pods even when the deployment is actually healthy — this is expected. After Maven exits, run the following.

### 5.1 Set KUBECONFIG

```bash
# On VM1 (.14)
export KUBECONFIG=~/data-space-connector/target/k3s.yaml

# On VM2 (.16) — kubectl may not be in PATH, use docker exec
alias kc='docker exec k3s-maven-plugin kubectl'
```

### 5.2 Restart crash-looping pods on VM2

These pods often crash on first start due to DNS timing. Restart them after the cluster is up:

```bash
docker exec k3s-maven-plugin kubectl rollout restart deployment/credentials-config-service -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/odrl-pap -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/trusted-issuers-list -n provider
docker exec k3s-maven-plugin kubectl rollout restart statefulset/provider-keycloak -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/contract-management -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/data-service-scorpio -n provider
```

Wait 2-3 minutes then check:

```bash
docker exec k3s-maven-plugin kubectl get pods -n provider | grep -v Running | grep -v Error | grep -v Completed
```

### 5.3 Restart crash-looping pods on VM1

```bash
export KUBECONFIG=~/data-space-connector/target/k3s.yaml
kubectl rollout restart deployment/tir -n trust-anchor
kubectl rollout restart statefulset/consumer-keycloak -n consumer
```

---

## 6. Health Checks

### 6.1 VM1 (.14) — all pods healthy

```bash
export KUBECONFIG=~/data-space-connector/target/k3s.yaml
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed | grep -v Error
# Should return empty
```

### 6.2 VM2 (.16) — all provider pods healthy

```bash
docker exec k3s-maven-plugin kubectl get pods -n provider | grep -v Running | grep -v Error | grep -v Completed
# Should return empty
```

### 6.3 Cross-VM endpoint tests (run from VM1)

```bash
# TIR on VM1
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .

# Provider data service on VM2 — should return 401 (auth enforced)
curl -s http://mp-data-service.192.168.120.16.nip.io:8080/ngsi-ld/v1/entities -w "\n%{http_code}\n"

# Provider PAP on VM2 — should return 200 with empty list
curl -s http://pap-provider.192.168.120.16.nip.io:8080/policy -w "\n%{http_code}\n"
```

---

## 7. Service Reference

| Service | VM | URL |
|---|---|---|
| Trust Anchor TIR | VM1 (.14) | `http://tir.192.168.120.14.nip.io:8080` |
| Trust Anchor TIL | VM1 (.14) | `http://til.192.168.120.14.nip.io:8080` |
| Consumer Keycloak | VM1 (.14) | `https://keycloak-consumer.192.168.120.14.nip.io` (via proxy :8888) |
| Consumer DID | VM1 (.14) | `http://did-consumer.192.168.120.14.nip.io:8080` |
| Squid Proxy | VM1 (.14) | `localhost:8888` |
| GX Registry | VM1 (.14) | `https://registry.192.168.120.14.nip.io` |
| Provider Data Service (APISIX) | VM2 (.16) | `http://mp-data-service.192.168.120.16.nip.io:8080` |
| Provider ODRL PAP | VM2 (.16) | `http://pap-provider.192.168.120.16.nip.io:8080` |
| Provider TM Forum API | VM2 (.16) | `http://mp-tmf-api.192.168.120.16.nip.io:8080` |
| Provider Keycloak | VM2 (.16) | `https://keycloak-provider.192.168.120.16.nip.io` (via proxy :8888) |
| Scorpio (direct) | VM2 (.16) | `kubectl port-forward svc/data-service-scorpio -n provider 8889:9090` |
| Contract Management | VM2 (.16) | `http://contract-management.192.168.120.16.nip.io:8080` |
| Provider DID | VM2 (.16) | `http://did-provider.192.168.120.16.nip.io:8080` |
| BAE Storefront (central) | VM2 (.16) | `https://marketplace.192.168.120.16.nip.io:8443` |

---

## 8. Troubleshooting

### 8.1 CoreDNS UDP timeout — pods crash with UnknownHostException

**Symptom:** `dial udp 10.43.0.10:53: i/o timeout`  
**Cause:** `br_netfilter` not loaded before Docker started K3s.  
**Fix:**
```bash
sudo modprobe br_netfilter
docker exec k3s-maven-plugin kubectl rollout restart deployment/coredns -n kube-system
# Then restart all crash-looping pods (see section 5.2)
```

### 8.2 Verifier crashes — cannot reach TIR

**Symptom:** `register-at-tir` init container fails with connection error to `tir.trust-anchor.svc.cluster.local`  
**Cause:** Internal cluster DNS reference not replaced with external IP.  
**Fix:** Run the sed commands from section 3.2.1 and redeploy.

### 8.3 database 'ngb' does not exist

**Symptom:** `contract-management` or `scorpio` crash with `FATAL: database "ngb" does not exist`  
**Cause:** `dsconfig` pod hasn't finished creating databases yet.  
**Fix:** Wait 2 minutes then restart:
```bash
docker exec k3s-maven-plugin kubectl rollout restart deployment/contract-management -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/data-service-scorpio -n provider
```

### 8.4 Maven times out but cluster is healthy

This is expected. The 300s timeout per resource is conservative. After Maven exits, check pod status manually and restart crash-looping pods as described in section 5. The cluster continues running after Maven exits.

### 8.5 Provider verifier cannot reach TIR on VM1

**Symptom:** verifier on VM2 fails to register with TIR  
**Cause:** VM1 deployment not finished or TIR not yet healthy.  
**Fix:** Ensure TIR on VM1 responds before starting VM2:
```bash
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .
```

---

## 9. Known Issues

| Issue | Notes |
|---|---|
| `br_netfilter` must be loaded manually | Ubuntu 25.04 kernel 6.14 does not auto-load `br_netfilter` inside Docker. Must run `sudo modprobe br_netfilter` before every Maven deploy. Survives reboots if `/etc/modules-load.d/br_netfilter.conf` is configured. |
| Maven times out at 300s per resource | Pods recover after Maven exits. Known limitation of the k3s-maven-plugin timeout model with this many services. |
| BAE biz-ecosystem pods deploy on provider VM | The `-Plocal` profile includes BAE components even without the central profile. They consume RAM but do not block core dataspace flows. |
| Central marketplace profile not tested in split | The `-Plocal,central` profile has not been tested in two-VM configuration. Additional pom modifications would be needed. |
| Operator credential returns null after Keycloak restart | Known upstream issue. Always do `mvn clean deploy` (not restart) to get a fresh Keycloak with proper realm import. |
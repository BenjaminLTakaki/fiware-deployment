# FIWARE Data Space Connector — Gaia-X on Two-VM Deployment Guide
*Profile: `-Plocal,gaia-x` across two VMs*

---

## 1. Overview

This guide documents deploying the FIWARE Data Space Connector with the Gaia-X profile (`-Plocal,gaia-x`) across two VMs, each with 16GB RAM. It extends the base two-VM deployment with Gaia-X specific components: a local GX Registry, `did:web` identity for the consumer, and ODRL policies using `ovc:Constraint`.

### 1.1 Architecture

| | VM1 — Consumer (.14) | VM2 — Provider (.16) |
|---|---|---|
| **IP** | 192.168.120.14 | 192.168.120.16 |
| **RAM / CPU** | 16GB / 8 cores | 16GB / 8 cores |
| **OS** | Ubuntu 25.04 | Ubuntu 25.04 |
| **Namespaces** | consumer, trust-anchor, infra, postgres-operator, mongo-operator, provider (dummy) | provider, mongo-operator, postgres-operator, cert-manager, infra |
| **Key Gaia-X services** | GX Registry, Squid Proxy, Consumer Keycloak (did:web), Traefik (HTTPS) | APISIX (auth-enforced), Provider Verifier, ODRL-PAP |
| **Maven pom** | pom-consumer.xml | pom-provider.xml |
| **Consumer DID** | `did:web:fancy-marketplace.biz` | — |

> ⚠️ **CRITICAL:** Always load `br_netfilter` BEFORE running Maven on both VMs.

> ⚠️ **IMPORTANT:** The Gaia-X profile is NOT compatible with a previous `-Plocal` or `-Plocal,central` deployment. Always do a full wipe before deploying with the gaia-x profile.

---

## 2. Prerequisites

Same as the base two-VM guide. Both VMs require Docker, Java 21, Maven, `yq`, `jq`, and `wget`. Verify `jq` is installed on VM1:

```bash
jq --version
# Expected: jq-1.7 or higher
```

---

## 3. Full Wipe (Required Before First Gaia-X Deploy)

Run on **both VMs** (order does not matter, can be done in parallel):

**VM1 (.14):**
```bash
docker ps -a | grep k3s | awk '{print $1}' | xargs -r docker rm -f
sudo modprobe br_netfilter
```

**VM2 (.16):**
```bash
docker ps -a | grep k3s | awk '{print $1}' | xargs -r docker rm -f
sudo modprobe br_netfilter
```

---

## 4. One-Time Configuration

### 4.1 VM1 (.14) — Consumer Side

#### 4.1.1 Reset and patch yaml files

```bash
cd ~/data-space-connector
git checkout k3s/consumer.yaml k3s/trust-anchor.yaml k3s/consumer-gaia-x.yaml

# Point consumer/trust-anchor to .14
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/consumer.yaml
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/trust-anchor.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/consumer.yaml

# Gaia-X specific
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.14.nip.io/g' k3s/consumer-gaia-x.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/consumer-gaia-x.yaml
```

#### 4.1.2 Fix mongo-operator namespace

The mongo-operator chart hardcodes `namespace: provider` in its values. VM1 doesn't run the provider, so patch it:

```bash
python3 << 'EOF'
with open('/home/ben/data-space-connector/k3s/mongo-operator.yaml', 'r') as f:
    content = f.read()
content = content.replace('  database:\n    namespace: provider', '  database:\n    namespace: consumer')
with open('/home/ben/data-space-connector/k3s/mongo-operator.yaml', 'w') as f:
    f.write(content)
print('Done')
EOF

# Verify
grep -A2 "database:" ~/data-space-connector/k3s/mongo-operator.yaml
# Expected: namespace: consumer
```

#### 4.1.3 Configure namespaces

```bash
cd ~/data-space-connector/k3s/namespaces/
rm -f provider.yaml wallet.yaml

# Add a dummy provider namespace to satisfy the mongo-operator chart
# (the chart renders provider-scoped RBAC resources regardless of profile)
cat > provider-dummy.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: provider
EOF
```

#### 4.1.4 Create pom-consumer.xml

```bash
cd ~/data-space-connector
cp pom.xml pom-consumer.xml

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

sed -i 's/<timeout>1500<\/timeout>/<timeout>300<\/timeout>/g' pom-consumer.xml
```

---

### 4.2 VM2 (.16) — Provider Side

#### 4.2.1 Reset and patch yaml files

```bash
cd ~/data-space-connector
git checkout k3s/provider.yaml k3s/provider-gaia-x.yaml

# Point provider to .16, fix TIR references back to .14
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.16.nip.io/g' k3s/provider.yaml
sed -i 's/tir\.192\.168\.120\.16\.nip\.io/tir.192.168.120.14.nip.io/g' k3s/provider.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/provider.yaml

# Gaia-X specific
sed -i 's/127\.0\.0\.1\.nip\.io/192.168.120.16.nip.io/g' k3s/provider-gaia-x.yaml
sed -i 's/tir\.192\.168\.120\.16\.nip\.io/tir.192.168.120.14.nip.io/g' k3s/provider-gaia-x.yaml
sed -i 's|http://tir.trust-anchor.svc.cluster.local:8080|http://tir.192.168.120.14.nip.io:8080|g' k3s/provider-gaia-x.yaml
```

#### 4.2.2 Configure namespaces

```bash
cd ~/data-space-connector/k3s/namespaces/
rm -f consumer.yaml trust-anchor.yaml wallet.yaml

cat > infra.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: infra
EOF
```

#### 4.2.3 Create pom-provider.xml

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

## 5. Certificate Generation (Gaia-X Specific — VM1 Only)

The Gaia-X profile requires a proper certificate chain for `did:web` and the GX Registry. This must be done **before** Maven deploys.

### 5.1 Run the cert script

```bash
cd ~/data-space-connector/helpers/certs/
bash generate-certs.sh
```

The script will print `CA already exists, skipping generation` if certs were previously generated — that is fine. It will then generate new client certs. It will fail at the end with a path error (`/consumer/tls-secret.yaml: No such file or directory`) because the `${k3sFolder}` variable is not set. This is expected — the certs themselves are generated correctly. Proceed to the next step.

### 5.2 Manually write the secret yaml files

The script fails to write the k3s secret yaml files due to the unset `${k3sFolder}` variable. Run the following to complete this step manually:

**On VM1 (.14):**
```bash
cd ~/data-space-connector/helpers/certs/
K3S_FOLDER=../../k3s
OUTPUT_FOLDER=./out

# Consumer secrets
kubectl create secret tls tls-secret \
  --cert=${OUTPUT_FOLDER}/client-consumer/certs/client-chain-bundle.cert.pem \
  --key=${OUTPUT_FOLDER}/client-consumer/private/client.key.pem \
  --namespace consumer -o yaml --dry-run=client \
  > ${K3S_FOLDER}/consumer/tls-secret.yaml

kubectl create secret generic consumer-keystore \
  --from-file=keystore.pfx=${OUTPUT_FOLDER}/client-consumer/keystore.pfx \
  --from-file=keystore-did.pfx=${OUTPUT_FOLDER}/client-consumer/keystore-did.pfx \
  --from-literal=password="password" \
  --namespace=consumer --dry-run=client -oyaml \
  > ${K3S_FOLDER}/consumer/keystore-secret.yaml

kubectl create secret generic cert-chain \
  --from-file=${OUTPUT_FOLDER}/client-consumer/certs/client-chain-bundle.cert.pem \
  --namespace consumer -o yaml --dry-run=client \
  > ${K3S_FOLDER}/consumer/cert-chain.yaml

openssl pkcs8 -topk8 -nocrypt \
  -in ${OUTPUT_FOLDER}/client-consumer/private/client.key.pem \
  -out ${OUTPUT_FOLDER}/client-consumer/private/client-pkcs8.key.pem

kubectl create secret generic signing-key \
  --from-file=${OUTPUT_FOLDER}/client-consumer/private/client.key.pem \
  --from-file=${OUTPUT_FOLDER}/client-consumer/private/client-pkcs8.key.pem \
  --namespace consumer -o yaml --dry-run=client \
  > ${K3S_FOLDER}/consumer/signing-key.yaml

consumer_key_env=$(openssl ec -in ${OUTPUT_FOLDER}/client-consumer/private/client.key.pem -noout -text | grep 'priv:' -A 3 | tail -n +2 | tr -d ':\n ')
kubectl create secret generic signing-key-env \
  --from-literal=key="${consumer_key_env}" \
  --namespace consumer -o yaml --dry-run=client \
  > ${K3S_FOLDER}/consumer/signing-key-env.yaml

# Provider secrets
kubectl create secret generic cert-chain \
  --from-file=${OUTPUT_FOLDER}/client-provider/certs/client-chain-bundle.cert.pem \
  --namespace provider -o yaml --dry-run=client \
  > ${K3S_FOLDER}/provider/cert-chain.yaml

provider_key_env=$(openssl ec -in ${OUTPUT_FOLDER}/client-provider/private/client.key.pem -noout -text | grep 'priv:' -A 3 | tail -n +2 | tr -d ':\n ')

openssl pkcs8 -topk8 -nocrypt \
  -in ${OUTPUT_FOLDER}/client-provider/private/client.key.pem \
  -out ${OUTPUT_FOLDER}/client-provider/private/client-pkcs8.key.pem

kubectl create secret tls tls-secret \
  --cert=${OUTPUT_FOLDER}/client-provider/certs/client-chain-bundle.cert.pem \
  --key=${OUTPUT_FOLDER}/client-provider/private/client.key.pem \
  --namespace provider -o yaml --dry-run=client \
  > ${K3S_FOLDER}/provider/tls-secret.yaml

kubectl create secret generic provider-keystore \
  --from-file=keystore.pfx=${OUTPUT_FOLDER}/client-provider/keystore.pfx \
  --from-file=keystore-did.pfx=${OUTPUT_FOLDER}/client-provider/keystore-did.pfx \
  --from-literal=password="password" \
  --namespace=provider --dry-run=client -oyaml \
  > ${K3S_FOLDER}/provider/keystore-secret.yaml

kubectl create secret generic signing-key \
  --from-file=${OUTPUT_FOLDER}/client-provider/private/client.key.pem \
  --from-file=${OUTPUT_FOLDER}/client-provider/private/client-pkcs8.key.pem \
  --namespace provider -o yaml --dry-run=client \
  > ${K3S_FOLDER}/provider/signing-key.yaml

kubectl create secret generic signing-key-env \
  --from-literal=key="${provider_key_env}" \
  --namespace provider -o yaml --dry-run=client \
  > ${K3S_FOLDER}/provider/signing-key-env.yaml

# Infra — wildcard TLS for Traefik
kubectl create secret tls local-wildcard \
  --cert=${OUTPUT_FOLDER}/client-wildcard/certs/client-chain-bundle.cert.pem \
  --key=${OUTPUT_FOLDER}/client-wildcard/private/client.key.pem \
  --namespace infra -o yaml --dry-run=client \
  > ${K3S_FOLDER}/certs/local-wildcard.yaml

# GX Registry keypair
kubectl create secret generic gx-registry-keypair \
  --from-file=PRIVATE_KEY=${OUTPUT_FOLDER}/ca/private/cakey-pkcs8.pem \
  --from-file=X509_CERTIFICATE=${OUTPUT_FOLDER}/ca/certs/cacert.pem \
  --namespace infra -o yaml --dry-run=client \
  > ${K3S_FOLDER}/infra/gx-registry/secret.yaml

# Root CA for verifier trust (both namespaces)
kubectl create secret generic root-ca \
  --from-file=${OUTPUT_FOLDER}/ca/certs/cacert.pem \
  --namespace provider -o yaml --dry-run=client \
  > ${K3S_FOLDER}/provider/root-ca.yaml

kubectl create secret generic root-ca \
  --from-file=${OUTPUT_FOLDER}/ca/certs/cacert.pem \
  --namespace consumer -o yaml --dry-run=client \
  > ${K3S_FOLDER}/consumer/root-ca.yaml

# Inject Root CA into gx-registry deployment via yq
ca=$(cat ${OUTPUT_FOLDER}/ca/certs/cacert.pem | sed '/-----BEGIN CERTIFICATE-----/d' | sed '/-----END CERTIFICATE-----/d' | tr -d '\n')
yq -i "(.spec.template.spec.initContainers[] | select(.name == \"local-trust\") | .env[] | select(.name == \"ROOT_CA\")).value = \"$ca\"" \
  ${K3S_FOLDER}/infra/gx-registry/deployment-registry.yaml

echo "All secrets written"
```

Verify the ROOT_CA injection worked:
```bash
grep -A2 "ROOT_CA" ~/data-space-connector/k3s/infra/gx-registry/deployment-registry.yaml | head -3
# Expected: value: "MII..." (long base64 string)
```

### 5.3 Copy provider secrets to VM2

The provider secret yaml files are generated on VM1 but needed by VM2's Maven deploy:

```bash
# On VM1 (.14)
cd ~/data-space-connector
scp k3s/provider/tls-secret.yaml \
    k3s/provider/cert-chain.yaml \
    k3s/provider/keystore-secret.yaml \
    k3s/provider/signing-key.yaml \
    k3s/provider/signing-key-env.yaml \
    k3s/provider/root-ca.yaml \
    ben@192.168.120.16:~/data-space-connector/k3s/provider/
```

---

## 6. Deployment

> ⚠️ Always start VM1 first and wait for TIR health before starting VM2.

### 6.1 Deploy VM1 (.14)

```bash
cd ~/data-space-connector
mvn clean deploy -Plocal,gaia-x -f pom-consumer.xml -Dhelm.version=3.14.0
```

Maven will time out at 300s per resource — this is expected. After it finishes (success or timeout), check TIR health:

```bash
export KUBECONFIG=~/data-space-connector/target/k3s.yaml
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .
# Expected: {"total": 0, "items": [], ...}
```

Only proceed to VM2 when TIR returns a valid JSON response.

### 6.2 Deploy VM2 (.16)

```bash
cd ~/data-space-connector
mvn clean deploy -Plocal,gaia-x -f pom-provider.xml -Dhelm.version=3.14.0
```

---

## 7. Post-Deploy Recovery

### 7.1 VM1 (.14)

```bash
export KUBECONFIG=~/data-space-connector/target/k3s.yaml
kubectl rollout restart deployment/tir -n trust-anchor
kubectl rollout restart statefulset/consumer-keycloak -n consumer
```

### 7.2 VM2 (.16)

```bash
docker exec k3s-maven-plugin kubectl rollout restart deployment/credentials-config-service -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/odrl-pap -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/trusted-issuers-list -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/contract-management -n provider
docker exec k3s-maven-plugin kubectl rollout restart deployment/data-service-scorpio -n provider
```

> Note: `provider-keycloak` statefulset is not present in the gaia-x profile — the error `not found` on this is expected.

Wait 2-3 minutes then verify:

**VM1:**
```bash
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed | grep -v Error
# Expected: empty (only header line)
```

**VM2:**
```bash
docker exec k3s-maven-plugin kubectl get pods --all-namespaces | grep -v Running | grep -v Completed | grep -v Error
# Expected: empty (only header line)
```

### 7.3 Fix APISIX route parsing bug (VM2)

The APISIX config is rendered with a `|-` YAML block scalar that prevents route parsing. Fix it after every deploy:

```bash
# On VM2 (.16)
docker exec k3s-maven-plugin kubectl get configmap apisix-routes -n provider \
  -o jsonpath='{.data.apisix\.yaml}' > /tmp/apisix-routes.yaml

python3 << 'EOF'
with open('/tmp/apisix-routes.yaml', 'r') as f:
    content = f.read()
lines = content.split('\n')
fixed_lines = []
for line in lines:
    if line.strip() == '|-':
        continue
    elif line.startswith('    '):
        fixed_lines.append(line[4:])
    else:
        fixed_lines.append(line)
fixed = '\n'.join(fixed_lines)
with open('/tmp/apisix-routes-fixed.yaml', 'w') as f:
    f.write(fixed)
print('Done')
EOF

docker exec k3s-maven-plugin kubectl patch configmap apisix-routes -n provider \
  --type merge \
  -p "{\"data\":{\"apisix.yaml\":$(python3 -c "import json; print(json.dumps(open('/tmp/apisix-routes-fixed.yaml').read()))")}}"

docker exec k3s-maven-plugin kubectl rollout restart deployment/provider-apisix -n provider
docker exec k3s-maven-plugin kubectl rollout status deployment/provider-apisix -n provider
```

### 7.4 Fix GX Registry BASE_URL (VM1)

The GX Registry is deployed with `BASE_URL` pointing to `127.0.0.1`. Patch it:

```bash
# On VM1 (.14)
export KUBECONFIG=~/data-space-connector/target/k3s.yaml
kubectl set env statefulset/gx-registry -n infra \
  BASE_URI=https://registry.192.168.120.14.nip.io/v2 \
  BASE_URL=https://registry.192.168.120.14.nip.io/v2
```

---

## 8. Health Checks

### 8.1 Gaia-X specific endpoints (run from VM1)

```bash
export KUBECONFIG=~/data-space-connector/target/k3s.yaml

# GX Registry (via Squid proxy)
curl -sk -x localhost:8888 https://registry.192.168.120.14.nip.io/v2 | jq .version
# Expected: "2.8.1"

# Consumer DID document (via Squid proxy)
curl --insecure -x http://localhost:8888 https://fancy-marketplace.biz/.well-known/did.json | jq .id
# Expected: "did:web:fancy-marketplace.biz"

# TIR
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .total
# Expected: 0 (or higher if participants registered)

# Provider PAP
curl -s http://pap-provider.192.168.120.16.nip.io:8080/policy -w "\n%{http_code}\n"
# Expected: []  200

# Provider Verifier
curl -s http://provider-verifier.192.168.120.16.nip.io:8080/health | jq .status
# Expected: "OK"

# Provider TIL
curl -s http://til-provider.192.168.120.16.nip.io:8080/issuer -w "\n%{http_code}\n" | tail -1
# Expected: 405 (GET not allowed, POST only — correct)
```

### 8.2 APISIX auth enforcement (from VM2)

```bash
# On VM2 (.16) — unauthenticated request should return 401
docker exec k3s-maven-plugin wget -qO- \
  --header='Host: mp-data-service.192.168.120.16.nip.io' \
  http://10.43.113.129:80/ngsi-ld/v1/entities 2>&1 | head -3
# Expected: HTTP/1.1 401 Unauthorized
```

---

## 9. Gaia-X Data Flow

### 9.1 Register consumer participant in TIR

```bash
# On VM1 (.14)
curl -X POST http://til.192.168.120.14.nip.io:8080/issuer \
  -H 'Content-Type: application/json' \
  -d '{"did": "did:web:fancy-marketplace.biz", "credentials": []}'

# Verify registration
curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .
# Expected: items contains did:web:fancy-marketplace.biz
```

### 9.2 Create a Gaia-X ODRL policy on the provider PAP

```bash
# On VM1 (.14)
curl -X POST http://pap-provider.192.168.120.16.nip.io:8080/policy \
  -H 'Content-Type: application/json' \
  -d '{
    "@context": {
      "odrl": "http://www.w3.org/ns/odrl/2/",
      "ovc": "https://w3id.org/gaia-x/ovc/1/",
      "rdfs": "http://www.w3.org/2000/01/rdf-schema#"
    },
    "@id": "urn:uuid:gaia-x-test-policy",
    "@type": "odrl:Policy",
    "odrl:profile": "https://github.com/DOME-Marketplace/dome-odrl-profile/blob/main/dome-op.ttl",
    "odrl:permission": {
      "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
      "odrl:target": "urn:ngsi-ld:Entity:gaia-x-test-entity",
      "odrl:assignee": {"@id": "vc:any"},
      "odrl:action": {"@id": "odrl:read"},
      "ovc:constraint": [{
        "ovc:leftOperand": "$.credentialSubject.gx:legalAddress.gx:countrySubdivisionCode",
        "odrl:operator": "odrl:anyOf",
        "odrl:rightOperand": ["FR-HDF", "BE-BRU"],
        "ovc:credentialSubjectType": "gx:LegalParticipant"
      }]
    }
  }'
```

Expected response: compiled Rego policy output starting with `package policy.`.

### 9.3 Create a test entity in Scorpio (VM2)

```bash
# On VM2 (.16)
SCORPIO_IP=$(docker exec k3s-maven-plugin kubectl get svc data-service-scorpio -n provider -o jsonpath='{.spec.clusterIP}')

docker exec k3s-maven-plugin wget -qO- \
  --post-data='{
    "@context": "https://uri.etsi.org/ngsi-ld/v1/ngsi-ld-core-context.jsonld",
    "id": "urn:ngsi-ld:Entity:gaia-x-test-entity",
    "type": "TestEntity",
    "name": {"type": "Property", "value": "Gaia-X Test Entity"}
  }' \
  --header='Content-Type: application/ld+json' \
  http://${SCORPIO_IP}:9090/ngsi-ld/v1/entities
echo "Exit: $?"
# Expected: Exit: 0 (201 Created, no body)

# Verify entity exists
docker exec k3s-maven-plugin wget -qO- \
  --header='Accept: application/json' \
  http://${SCORPIO_IP}:9090/ngsi-ld/v1/entities/urn:ngsi-ld:Entity:gaia-x-test-entity
```

---

## 10. Service Reference

| Service | VM | URL |
|---|---|---|
| Trust Anchor TIR | VM1 (.14) | `http://tir.192.168.120.14.nip.io:8080` |
| Trust Anchor TIL | VM1 (.14) | `http://til.192.168.120.14.nip.io:8080` |
| Consumer Keycloak | VM1 (.14) | `http://keycloak-consumer.192.168.120.14.nip.io:8080` |
| Consumer DID | VM1 (.14) | `https://fancy-marketplace.biz/.well-known/did.json` (via Squid :8888) |
| GX Registry | VM1 (.14) | `https://registry.192.168.120.14.nip.io/v2` (via Squid :8888) |
| Squid Proxy | VM1 (.14) | `localhost:8888` |
| Provider PAP | VM2 (.16) | `http://pap-provider.192.168.120.16.nip.io:8080` |
| Provider Verifier | VM2 (.16) | `http://provider-verifier.192.168.120.16.nip.io:8080` |
| Provider TIL | VM2 (.16) | `http://til-provider.192.168.120.16.nip.io:8080` |
| Provider TM Forum API | VM2 (.16) | `http://tm-forum-api.192.168.120.16.nip.io:8080` |
| Provider CCS | VM2 (.16) | `http://provider-ccs.192.168.120.16.nip.io:8080` |
| Scorpio (direct) | VM2 (.16) | ClusterIP only — use `docker exec k3s-maven-plugin wget` |
| APISIX Gateway | VM2 (.16) | ClusterIP only — use `docker exec k3s-maven-plugin wget` with `Host:` header |

> **Note:** APISIX and Scorpio are not externally reachable via nip.io in the 2VM setup. The Traefik LoadBalancer on VM2 gets a Docker bridge IP (`172.17.0.2`) instead of the VM's actual IP, so NodePorts are not reachable from VM1. Use `docker exec k3s-maven-plugin wget` with the ClusterIP for direct access, or use the Traefik-routed endpoints on port 8080 with explicit `Host:` headers for services that have ingresses.

---

## 11. Keycloak Admin Reference

| Parameter | Value |
|---|---|
| Admin username | `keycloak-admin` |
| Admin password | Retrieved from secret: `kubectl get secret issuance-secret -n consumer -o jsonpath='{.data.keycloak-admin}' \| base64 -d` |
| Realm | `test-realm` |
| Consumer DID client | `did:web:fancy-marketplace.biz` |
| Test user | `test-user` / `test` |

---

## 12. Known Issues and Workarounds

| Issue | Cause | Workaround |
|---|---|---|
| `generate-certs.sh` fails with `No such file or directory` | `${k3sFolder}` variable not set in script | Run the manual secret-writing commands in Section 5.2 |
| mongo-operator chart renders `namespace: provider` on VM1 | Chart hardcodes provider namespace in `database_roles.yaml` | Patch `k3s/mongo-operator.yaml` to use `namespace: consumer` and add a dummy provider namespace (Section 4.1.2 and 4.1.3) |
| APISIX returns 404 on all routes after deploy | `apisix.yaml` configmap renders routes as a YAML string (`\|-`) instead of a list | Run the APISIX route fix script after every deploy (Section 7.3) |
| GX Registry returns 404 on all endpoints | `BASE_URL` defaults to `127.0.0.1` | Patch the statefulset env var after deploy (Section 7.4) |
| APISIX and Scorpio not reachable from VM1 via nip.io | Traefik LoadBalancer binds to Docker bridge IP `172.17.0.2` instead of `192.168.120.16` | Use `docker exec k3s-maven-plugin wget` with ClusterIP, or use Host header override on port 8080 |
| Consumer Keycloak realm imports with `${CLIENT_DID}` unexpanded | Keycloak 26 `IGNORE_EXISTING` import strategy skips re-import if realm exists | Delete the realm via admin API then restart Keycloak to force fresh import |
| OID4VCI credential issuance fails via curl | Keycloak 26 `oid4vc` protocol client does not support standard password grant or direct credential endpoint access without a wallet | The full OID4VCI flow requires a wallet client (e.g. EUDI Android Wallet). curl-based credential issuance is not supported by Keycloak 26's oid4vc implementation. The deployment is validated up to APISIX auth enforcement (401 on unauthenticated, policy compilation confirmed). |
| Maven times out at 300s | Conservative timeout in k3s-maven-plugin | Expected — pods recover after Maven exits. Check pod status manually and restart crash-looping pods (Section 7). |
| `br_netfilter` must be loaded manually | Ubuntu 25.04 kernel does not auto-load it inside Docker | Run `sudo modprobe br_netfilter` before every Maven deploy. Survives reboots if `/etc/modules-load.d/br_netfilter.conf` is configured. |

---

## 13. Troubleshooting

### CoreDNS UDP timeout
**Symptom:** `dial udp 10.43.0.10:53: i/o timeout`
**Fix:**
```bash
sudo modprobe br_netfilter
docker exec k3s-maven-plugin kubectl rollout restart deployment/coredns -n kube-system
```

### Verifier cannot reach TIR
**Symptom:** `register-at-tir` init container fails
**Fix:** Ensure VM1 TIR is healthy before starting VM2. Check: `curl -s http://tir.192.168.120.14.nip.io:8080/v4/issuers | jq .`

### Keycloak realm imports with unexpanded variables
**Symptom:** Client listed as `${CLIENT_DID}` in admin console
**Fix:**
```bash
ADMIN_TOKEN=$(curl -s http://keycloak-consumer.192.168.120.14.nip.io:8080/realms/master/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=admin-cli&username=keycloak-admin&password=<PASSWORD>' | jq -r .access_token)
curl -s -X DELETE http://keycloak-consumer.192.168.120.14.nip.io:8080/admin/realms/test-realm \
  -H "Authorization: Bearer $ADMIN_TOKEN"
kubectl rollout restart statefulset/consumer-keycloak -n consumer
```

### APISIX routes not loading
**Symptom:** APISIX logs show `bad argument #1 to 'ipairs' (table expected, got string)`
**Fix:** Run the APISIX route fix script from Section 7.3.
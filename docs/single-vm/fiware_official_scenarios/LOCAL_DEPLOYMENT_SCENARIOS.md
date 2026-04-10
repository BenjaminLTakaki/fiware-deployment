# Minimum Viable Dataspace -- Deployment & Exploration Journey

This document logs the full deployment and demo walkthrough of the FIWARE Data Space Connector MVD on a local K3s cluster (Multipass Ubuntu VM). It covers environment setup, all phases of the LOCAL.md guide, troubleshooting notes, and discovered bugs.

---

## 1. Environment Setup

### 1.1 Kernel Modules

K3s networking requires `br_netfilter`. If `./checkRequirements.sh` reports it missing:

```bash
sudo modprobe br_netfilter
./checkRequirements.sh   # no output = success
```

### 1.2 Docker Permissions

If the Maven build throws `java.net.BindException: Permission denied`:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 1.3 Cleaning Up Previous K3s Deployments

If a previous K3s cluster left orphaned Docker containers, the new deploy will fail with port conflicts. Kill them first:

```bash
docker ps -a | grep k3s | awk '{print $1}' | xargs -r docker rm -f
```

---

## 2. Deployment

Use the local Maven profile. If GitHub rate-limits the Helm download (HTTP 403), pass the version explicitly:

```bash
mvn clean deploy -Plocal -Dhelm.version=3.14.0
```

Build takes roughly 10 minutes. Success looks like:

```
[INFO] connector .......................................... SUCCESS [09:25 min]
[INFO] it ................................................. SUCCESS [ 21.520 s]
[INFO] BUILD SUCCESS
```

After deployment, set `KUBECONFIG`:

```bash
export KUBECONFIG=$(pwd)/target/k3s.yaml
kubectl get all --all-namespaces
```

---

## 3. Phase 1: Trust Anchor & Trusted Issuers

Verify the Trust Anchor is running with two pre-configured issuers:

```bash
curl -s http://tir.127.0.0.1.nip.io:8080/v4/issuers | jq .
```

Expected output:

```json
{
  "self": "http://tir.127.0.0.1.nip.io:8080/v4/issuers",
  "items": [
    { "did": "did:web:fancy-marketplace.biz" },
    { "did": "did:web:mp-operations.org" }
  ],
  "total": 2
}
```

---

## 4. Phase 2: Verifiable Credential Issuance

Three credential types exist. Use the helper scripts to issue all three:

```bash
export USER_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io user-credential employee)
export REP_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io user-credential representative)
export OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io operator-credential operator)
```

All three should return `eyJ...` JWT strings. If any returns `null`, see the troubleshooting section below.

### 4.1 Manual OID4VC Flow (for reference)

The helper scripts automate this, but the manual flow is:

1. Authenticate with Keycloak via password grant (uses squid proxy on port 8888 for HTTPS)
2. Request credential offer URI from `/realms/test-realm/protocol/oid4vc/credential-offer-uri`
3. Resolve the offer to get a pre-authorized code
4. Exchange code for credential access token
5. Fetch the VC JWT from `/realms/test-realm/protocol/oid4vc/credential`

### 4.2 Troubleshooting: operator-credential Returns Null

**Root cause:** Keycloak parses `vc.*` realm attributes only during initial realm import. If the Keycloak StatefulSet restarts (e.g. during debugging), the `.well-known/openid-credential-issuer` endpoint returns `credential_configurations_supported: {}` and credential issuance silently returns null.

**Fix:** Clean redeploy (`mvn clean deploy -Plocal`). There is no way to re-trigger realm attribute parsing without reimporting.

**How to verify:** Check the credential issuer metadata:

```bash
curl -s -k -x localhost:8888 https://keycloak-consumer.127.0.0.1.nip.io/realms/test-realm/.well-known/openid-credential-issuer | jq '.credential_configurations_supported | keys'
```

Should list all 7 types including `operator-credential`.

---

## 5. Phase 3: Data Provider Setup & Authenticated Access

### 5.1 Create ODRL Policy for EnergyReport

```bash
curl -s -X POST http://pap-provider.127.0.0.1.nip.io:8080/policy \
  -H 'Content-Type: application/json' \
  -d '{
    "@context": { "dc": "http://purl.org/dc/elements/1.1/", "dct": "http://purl.org/dc/terms/", "owl": "http://www.w3.org/2002/07/owl#", "odrl": "http://www.w3.org/ns/odrl/2/", "rdfs": "http://www.w3.org/2000/01/rdf-schema#", "skos": "http://www.w3.org/2004/02/skos/core#" },
    "@id": "https://mp-operation.org/policy/common/type",
    "@type": "odrl:Policy",
    "odrl:permission": {
      "odrl:assigner": { "@id": "https://www.mp-operation.org/" },
      "odrl:target": { "@type": "odrl:AssetCollection", "odrl:source": "urn:asset", "odrl:refinement": [{ "@type": "odrl:Constraint", "odrl:leftOperand": "ngsi-ld:entityType", "odrl:operator": { "@id": "odrl:eq" }, "odrl:rightOperand": "EnergyReport" }] },
      "odrl:assignee": { "@type": "odrl:PartyCollection", "odrl:source": "urn:user" },
      "odrl:action": { "@id": "odrl:read" }
    }
  }'
```

### 5.2 Create Test Entity

```bash
curl -s -X POST http://scorpio-provider.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "urn:ngsi-ld:EnergyReport:fms-1",
    "type": "EnergyReport",
    "name": { "type": "Property", "value": "Standard Server" },
    "consumption": { "type": "Property", "value": "94" }
  }'
```

### 5.3 Authenticated Retrieval via OID4VP

Without a token, APISIX returns 401. Use the helper script:

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $USER_CREDENTIAL default)
curl -s http://mp-data-service.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1 \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq .
```

**Note:** OPA may take ~5 seconds to pick up new policies after creation. If you get a 403 right after creating the policy, wait a few seconds and retry.

---

## 6. Phase 4: Marketplace Operations

### 6.1 Create Marketplace Access Policies

Four policies are needed for marketplace operations (offering read, self-registration, ordering, K8SCluster read). See LOCAL.md steps 1-4 for the full policy JSON bodies. All four should return Rego translations.

### 6.2 Product Specifications & Offerings

Create two product specifications (small and full) and their corresponding offerings:

```bash
# Small spec (numNodes <= 3)
export PRODUCT_SPEC_SMALL_ID=$(curl -s -X POST http://tm-forum-api.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productSpecification \
  -H 'Content-Type: application/json' \
  -d '{ ... }' | jq '.id' -r)

# Full spec (no constraint)
export PRODUCT_SPEC_FULL_ID=$(curl -s -X POST http://tm-forum-api.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productSpecification \
  -H 'Content-Type: application/json' \
  -d '{ ... }' | jq '.id' -r)

# Create offerings referencing the specs
export PRODUCT_OFFERING_SMALL_ID=$(curl -s -X POST ... | jq '.id' -r)
export PRODUCT_OFFERING_FULL_ID=$(curl -s -X POST ... | jq '.id' -r)
```

### 6.3 Pre-Purchase Verification

Before buying, verify that access is correctly denied:

- USER_CREDENTIAL with `default` scope gets a valid token but K8SCluster creation returns **403** (no K8SCluster policy for user-credential)
- OPERATOR_CREDENTIAL with `operator` scope returns **null** token (OperatorCredential not yet registered in TIR for `did:web:fancy-marketplace.biz`)

### 6.4 Customer Registration

Register Fancy Marketplace as a customer of M&P Operations:

```bash
export CONSUMER_DID="did:web:fancy-marketplace.biz"
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $REP_CREDENTIAL default)
export FANCY_MARKETPLACE_ID=$(curl -s -X POST http://mp-tmf-api.127.0.0.1.nip.io:8080/tmf-api/party/v4/organization \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{
    \"name\": \"Fancy Marketplace Inc.\",
    \"partyCharacteristic\": [{\"name\": \"did\", \"value\": \"${CONSUMER_DID}\"}]
  }" | jq '.id' -r)
echo "FANCY_MARKETPLACE_ID: ${FANCY_MARKETPLACE_ID}"
```

### 6.5 Order Placement & Completion

```bash
# Get offering ID (.[1] for full offering, .[0] for small)
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $REP_CREDENTIAL default)
export OFFER_ID=$(curl -s http://mp-tmf-api.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq '.[1].id' -r)

# Place order
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $REP_CREDENTIAL default)
export ORDER_ID=$(curl -s -X POST http://mp-tmf-api.127.0.0.1.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{\"productOrderItem\":[{\"id\":\"order-1\",\"action\":\"add\",\"productOffering\":{\"id\":\"${OFFER_ID}\"}}],\"relatedParty\":[{\"id\":\"${FANCY_MARKETPLACE_ID}\"}]}" | jq '.id' -r)

# Complete order
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $REP_CREDENTIAL default)
curl -s -X PATCH http://tm-forum-api.127.0.0.1.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder/${ORDER_ID} \
  -H 'Content-Type: application/json;charset=utf-8' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d '{"state":"completed"}' | jq '.state'
```

### 6.6 Contract Management Event Processing

When the order is completed, TMForum sends a `ProductOrderStateChangeEvent` to the contract-management service at `http://contract-management:8080/listener/event`. Contract management then:

1. **PapProductOrderHandler:** Resolves the organization DID, fetches the product offering + spec, extracts the ODRL policy, adds the consumer's DID as a party constraint, and POSTs the policy to the ODRL-PAP. Logs `Handler org.fiware.iam.pap.PapProductOrderHandler responded 200 OK`.
2. **TilProductOrderHandler:** Reads the credential config from the product spec, GETs the existing TIR entry for `did:web:fancy-marketplace.biz`, adds the `OperatorCredential` with claim constraints, and PUTs the updated issuer entry. Logs `Handler org.fiware.iam.til.TilProductOrderHandler responded 201 Created`.

**Known issue:** TMForum delivers the same event to multiple subscriptions (contract management registers ~13 subscriptions on startup). The first processing succeeds, but duplicate concurrent attempts to POST the same policy to the ODRL-PAP get a 500 (duplicate UID). These 500 errors are logged as `CatchAllExceptionHandler - Received unexpected exception` with `HttpClientResponseException: 500 - Internal Server Error` from `odrl-pap:8080/policy`. This is a harmless race condition. The TIR and PAP updates succeed on the first pass.

### 6.7 Operator Token Exchange (Post-Purchase)

After the order is processed, the operator credential now works:

```bash
export OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io operator-credential operator)
export OPERATOR_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $OPERATOR_CREDENTIAL operator)
echo "OPERATOR_TOKEN: ${OPERATOR_TOKEN:0:20}..."
# Should print: OPERATOR_TOKEN: eyJhbGciOiJSUzI1NiIs...
```

### 6.8 K8SCluster Creation & Access Control Verification

```bash
# Create cluster with operator token (succeeds)
curl -s -X POST http://mp-data-service.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "urn:ngsi-ld:K8SCluster:test-cluster-1",
    "type": "K8SCluster",
    "name": {"type": "Property", "value": "test-cluster"},
    "numNodes": {"type": "Property", "value": 3}
  }' -w "\n%{http_code}\n"
# Returns: 201

# Create second cluster with 4 nodes (also succeeds because full offering has no numNodes constraint)
export OPERATOR_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $OPERATOR_CREDENTIAL operator)
curl -s -X POST http://mp-data-service.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "urn:ngsi-ld:K8SCluster:test-cluster-2",
    "type": "K8SCluster",
    "name": {"type": "Property", "value": "big-cluster"},
    "numNodes": {"type": "Property", "value": 4}
  }' -w "\n%{http_code}\n"
# Returns: 201 (expected -- full offering policy k8s-full has no numNodes constraint)

# Retrieve clusters with operator token (succeeds)
export OPERATOR_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $OPERATOR_CREDENTIAL operator)
curl -s http://mp-data-service.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities?type=K8SCluster \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" | jq '.[].id'
# Returns:
# "urn:ngsi-ld:K8SCluster:test-cluster-1"
# "urn:ngsi-ld:K8SCluster:test-cluster-2"

# Try with USER_CREDENTIAL (denied)
export USER_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $USER_CREDENTIAL default)
curl -s http://mp-data-service.127.0.0.1.nip.io:8080/ngsi-ld/v1/entities?type=K8SCluster \
  -H "Authorization: Bearer ${USER_TOKEN}" -w "\n%{http_code}\n"
# Returns: 403 Forbidden
```

---

## 7. Troubleshooting Reference

### 7.1 CCS `jwtInclusion` NullPointerException

When updating the Credentials Config Service (CCS), every credential entry in the JSON body must include `"jwtInclusion": {"enabled": false}`, even if JWT inclusion is not used. Omitting it causes a NullPointerException and a 500 error from CCS.

### 7.2 Keycloak Admin Access

The Keycloak admin password is dynamically generated. To retrieve it:

```bash
kubectl exec -n consumer -it statefulset/consumer-keycloak -- env | grep KC_ADMIN_PASSWORD
```

Username is `keycloak-admin`. Keycloak uses Bitnami paths (`/opt/bitnami/keycloak/`). Port-forward for admin API access:

```bash
kubectl port-forward svc/consumer-keycloak -n consumer 9898:8080
```

### 7.3 Squid Proxy for HTTPS

All HTTPS requests to `*.nip.io` domains require the squid proxy on port 8888:

```bash
curl -k -x localhost:8888 https://keycloak-consumer.127.0.0.1.nip.io/...
```

The helper scripts handle this automatically.

### 7.4 OPA Policy Propagation Delay

After creating an ODRL policy, OPA needs a few seconds to compile and load it. If you get a 403 immediately after policy creation, wait ~5 seconds and retry.

### 7.5 Contract Management 500 Errors

These are expected. See section 6.6 for the full explanation. The 500s come from duplicate TMForum event delivery, not from a functional failure. Verify success by checking that the operator token works (section 6.7).

---

## 8. Service Reference

| Service | Namespace | Access Method |
|---|---|---|
| K3s Ingress HTTP | -- | Port 8080 direct |
| K3s Ingress HTTPS | -- | Port 8443 direct |
| Squid proxy | consumer | Port 8888 (for HTTPS to *.nip.io) |
| Keycloak admin | consumer | `kubectl port-forward svc/consumer-keycloak -n consumer 9898:8080` |
| Scorpio direct | provider | `http://scorpio-provider.127.0.0.1.nip.io:8080` |
| ODRL PAP | provider | `http://pap-provider.127.0.0.1.nip.io:8080` |
| Data service (APISIX) | provider | `http://mp-data-service.127.0.0.1.nip.io:8080` |
| TMForum API (provider) | provider | `http://tm-forum-api.127.0.0.1.nip.io:8080` |
| TMForum API (marketplace) | provider | `http://mp-tmf-api.127.0.0.1.nip.io:8080` |
| Trust Anchor TIR | trust-anchor | `http://tir.127.0.0.1.nip.io:8080` |
| Trust Anchor TIL | trust-anchor | `http://til.127.0.0.1.nip.io:8080` |
| Consumer DID | consumer | `http://did-consumer.127.0.0.1.nip.io:8080` |
| Provider DID | provider | `http://did-provider.127.0.0.1.nip.io:8080` |

---

## 9. Demo Flow Summary

| Step | Status | Notes |
|---|---|---|
| Environment setup (br_netfilter, docker) | Done | |
| `mvn clean deploy -Plocal` | Done | Kill orphaned k3s containers first if redeploying |
| Trust Anchor: 2 issuers verified | Done | `did:web:fancy-marketplace.biz`, `did:web:mp-operations.org` |
| Credential issuance: user-credential (employee) | Done | JWT returned |
| Credential issuance: user-credential (representative) | Done | JWT returned |
| Credential issuance: operator-credential (operator) | Done | JWT returned (requires fresh deploy) |
| ODRL policy for EnergyReport | Done | |
| EnergyReport entity creation | Done | |
| Authenticated EnergyReport retrieval (OID4VP) | Done | Wait ~5s for OPA after policy creation |
| Marketplace policies (4x) | Done | offering read, selfRegistration, ordering, K8SCluster read |
| Product specs (small + full) | Done | |
| Product offerings (small + full) | Done | |
| Pre-purchase: USER_CREDENTIAL gets 403 on K8SCluster | Done | |
| Pre-purchase: OPERATOR_CREDENTIAL returns null token | Done | |
| Customer registration (Fancy Marketplace) | Done | |
| Order placement + completion (full offering) | Done | |
| Contract management: PAP policy created | Done | Harmless 500s from duplicate event delivery |
| Contract management: TIR updated with OperatorCredential | Done | |
| Operator token exchange via OID4VP | Done | Returns valid JWT |
| K8SCluster creation (3 nodes) with operator token | Done | 201 Created |
| K8SCluster creation (4 nodes) with operator token | Done | 201 Created (full offering, no constraint) |
| K8SCluster retrieval with operator token | Done | Returns both entities |
| K8SCluster access denied for user token | Done | 403 Forbidden |
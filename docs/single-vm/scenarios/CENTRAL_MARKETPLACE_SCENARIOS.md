# Central Marketplace -- Deployment & Configuration Journey

Project Context: Fontys ICT & AI -- Implementing a Marketplace in a DataSpace
Architecture: FIWARE Data Space Connector (Central Marketplace Profile)

---

## 1. Introduction

This document logs the deployment, configuration, and verification of a Central Marketplace acting as an orchestrating layer within a FIWARE DataSpace. Unlike the standard MVD peer-to-peer setup, this architecture introduces a neutral third-party storefront (Fancy Marketplace / `did:web:fancy-marketplace.biz`) that brokers transactions between a Data Provider (M&P Operations / `did:web:mp-operations.org`) and Data Consumers.

The key architectural difference is the contract management notification chain: when a consumer completes an order on the central marketplace, the marketplace's own contract-management authenticates with the provider's verifier using a `MarketplaceCredential` and forwards the order event to the provider's contract-management, which then updates the TIR and PAP.

---

## 2. Environment Teardown & Deployment

### 2.1 Clearing the Local Sandbox

Any previous K3s clusters must be destroyed to prevent port conflicts:

```bash
docker ps -a | grep k3s | awk '{print $1}' | xargs -r docker rm -f
```

### 2.2 Orchestrator Deployment

The `central` Maven profile deploys the orchestrator node, TMForum APIs for both provider and consumer, the BAE storefront, and contract-management instances in both namespaces:

```bash
cd ~/data-space-connector
mvn clean deploy -Plocal,central -Dhelm.version=3.14.0
```

Build output:

```
[INFO] connector .......................................... SUCCESS [09:27 min]
[INFO] it ................................................. SUCCESS [  1.389 s]
[INFO] BUILD SUCCESS
```

After deployment:

```bash
export KUBECONFIG=$(pwd)/target/k3s.yaml
kubectl get pods --all-namespaces
```

The central profile deploys pods across namespaces: `consumer`, `provider`, `trust-anchor`, `infra`, and `wallet`. Notable additions compared to the standard MVD profile include BAE components (`provider-biz-ecosystem-charging-backend`, `provider-biz-ecosystem-logic-proxy`), a `dsconfig` pod, and a `mongodb` instance in the provider namespace.

---

## 3. Phase 1: Marketplace Policy Preparation & Provider Integration

### 3.1 Generate Central Marketplace Policies

Five Rego policies are generated to restrict TMForum API access on the marketplace. These enforce that only users with the `REPRESENTATIVE` role can create organizations, manage product specs/offerings, and place orders:

```bash
./doc/scripts/prepare-central-market-policies.sh
```

This outputs five `package policy.*` Rego translations covering: organization creation, product order use, product offering use/read, and product specification use.

### 3.2 Allow Contract Management Access at the Provider

The provider creates a policy permitting requests authenticated with a `MarketplaceCredential` to access the `/order` path on its contract-management endpoint:

```bash
curl -X 'POST' http://pap-provider.127.0.0.1.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d "$(cat ./it/src/test/resources/policies/allowContractManagement.json)"
```

Output: Rego policy `package policy.shusaxmnup` requiring `MarketplaceCredential` type and `/order` path constraint.

### 3.3 Provider Credential Issuance

```bash
export PROVIDER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-provider.127.0.0.1.nip.io user-credential employee)
echo ${PROVIDER_USER_CREDENTIAL}
# Returns: eyJhbGciOiJFUzI1NiIs... (JWT with roles: seller, REPRESENTATIVE, admin targeting did:web:fancy-marketplace.biz)
```

**Key difference from MVD:** The provider credential is issued by `did:web:mp-operations.org` (provider's Keycloak), not the consumer's Keycloak. The roles target `did:web:fancy-marketplace.biz` because the provider needs to interact with the central marketplace's TMForum API.

### 3.4 Register Provider as Seller on Central Marketplace

The provider registers as an organization on the marketplace, including contract-management access information:

```bash
export PROVIDER_DID="did:web:mp-operations.org"
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)
export MP_OPERATIONS_ID=$(curl -X POST http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/party/v4/organization \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{
    \"name\": \"M&P Operations Org.\",
    \"partyCharacteristic\": [
      {\"name\": \"did\", \"value\": \"${PROVIDER_DID}\"},
      {\"name\": \"contractManagement\", \"value\": {
        \"address\": \"http://contract-management.127.0.0.1.nip.io:8080\",
        \"clientId\": \"contract-management\",
        \"scope\": [\"external-marketplace\"]
      }}
    ]
  }" | jq '.id' -r)
echo "MP_OPERATIONS_ID: ${MP_OPERATIONS_ID}"
# Returns: urn:ngsi-ld:organization:523cdbff-6105-46cc-aa89-412ea416786b
```

The `contractManagement` characteristic tells the marketplace where to send order notifications and what credential scope to use for authentication.

---

## 4. Phase 2: Product Catalog Setup

### 4.1 Create Product Specification

The provider pushes a product spec to the central marketplace catalog, referencing themselves via `relatedParty` and embedding both credential configuration (OperatorCredential with OPERATOR role) and an ODRL authorization policy (K8SCluster read/write with OperatorCredential + OPERATOR role):

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)
export PRODUCT_SPEC=$(curl -X 'POST' http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productSpecification \
  -H 'Content-Type: application/json;charset=utf-8' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{
    \"brand\": \"M&P Operations\",
    \"version\": \"1.0.0\",
    \"lifecycleStatus\": \"ACTIVE\",
    \"name\": \"M&P K8S\",
    \"relatedParty\": [{\"id\": \"${MP_OPERATIONS_ID}\", \"role\": \"provider\"}],
    \"productSpecCharacteristic\": [
      {
        \"id\": \"credentialsConfig\",
        \"name\": \"Credentials Config\",
        \"valueType\": \"credentialsConfiguration\",
        \"productSpecCharacteristicValue\": [{
          \"isDefault\": true,
          \"value\": {
            \"credentialsType\": \"OperatorCredential\",
            \"claims\": [{\"name\": \"roles\", \"path\": \"$.roles[?(@.target==\\\"${PROVIDER_DID}\\\")].names[*]\", \"allowedValues\": [\"OPERATOR\"]}]
          }
        }]
      },
      {
        \"id\": \"policyConfig\",
        \"name\": \"Policy for creation of K8S clusters.\",
        \"valueType\": \"authorizationPolicy\",
        \"productSpecCharacteristicValue\": [{
          \"isDefault\": true,
          \"value\": {
            \"@context\": {\"odrl\": \"http://www.w3.org/ns/odrl/2/\"},
            \"@id\": \"https://mp-operation.org/policy/common/k8s-full\",
            \"odrl:uid\": \"https://mp-operation.org/policy/common/k8s-full\",
            \"@type\": \"odrl:Policy\",
            \"odrl:permission\": {
              \"odrl:assigner\": \"https://www.mp-operation.org/\",
              \"odrl:target\": {\"@type\": \"odrl:AssetCollection\", \"odrl:source\": \"urn:asset\", \"odrl:refinement\": [{\"@type\": \"odrl:Constraint\", \"odrl:leftOperand\": \"ngsi-ld:entityType\", \"odrl:operator\": \"odrl:eq\", \"odrl:rightOperand\": \"K8SCluster\"}]},
              \"odrl:assignee\": {\"@type\": \"odrl:PartyCollection\", \"odrl:source\": \"urn:user\", \"odrl:refinement\": {\"@type\": \"odrl:LogicalConstraint\", \"odrl:and\": [{\"@type\": \"odrl:Constraint\", \"odrl:leftOperand\": \"vc:role\", \"odrl:operator\": \"odrl:hasPart\", \"odrl:rightOperand\": {\"@value\": \"OPERATOR\", \"@type\": \"xsd:string\"}}, {\"@type\": \"odrl:Constraint\", \"odrl:leftOperand\": \"vc:type\", \"odrl:operator\": \"odrl:hasPart\", \"odrl:rightOperand\": {\"@value\": \"OperatorCredential\", \"@type\": \"xsd:string\"}}]}},
              \"odrl:action\": \"odrl:use\"
            }
          }
        }]
      }
    ]
  }" | jq '.id' -r)
echo "PRODUCT_SPEC: ${PRODUCT_SPEC}"
# Returns: urn:ngsi-ld:product-specification:0c0917dd-d4ba-47d6-a055-e47e4ca8cbca
```

### 4.2 Create Product Offering

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)
export PRODUCT_OFFERING_ID=$(curl -X 'POST' http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
  -H 'Content-Type: application/json;charset=utf-8' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{
    \"version\": \"1.0.0\",
    \"lifecycleStatus\": \"ACTIVE\",
    \"name\": \"M&P K8S Offering\",
    \"productSpecification\": {\"id\": \"${PRODUCT_SPEC}\"}
  }" | jq '.id' -r)
echo "PRODUCT_OFFERING_ID: ${PRODUCT_OFFERING_ID}"
# Returns: urn:ngsi-ld:product-offering:35fdf42a-a903-4c0f-8934-2679312487b3
```

---

## 5. Phase 3: Consumer Transaction

### 5.1 Consumer Credential Issuance

```bash
# SD-JWT user credential (note: uses user-sd type and vc+sd-jwt format, unlike MVD's plain user-credential)
export CONSUMER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io user-sd employee vc+sd-jwt)

# Operator credential
export CONSUMER_OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh https://keycloak-consumer.127.0.0.1.nip.io operator-credential operator)
```

Both return JWT strings successfully.

### 5.2 Pre-Purchase Verification

Before buying, confirm the operator credential cannot yet access the provider's data service:

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $CONSUMER_OPERATOR_CREDENTIAL operator)
echo ${ACCESS_TOKEN}
# Returns: null (expected -- OperatorCredential not yet registered in TIR for did:web:fancy-marketplace.biz)
```

### 5.3 Consumer Registration

```bash
export CONSUMER_DID="did:web:fancy-marketplace.biz"
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)
export FANCY_MARKETPLACE_ID=$(curl -X POST http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/party/v4/organization \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{
    \"name\": \"Fancy Marketplace Inc.\",
    \"partyCharacteristic\": [{\"name\": \"did\", \"value\": \"${CONSUMER_DID}\"}]
  }" | jq '.id' -r)
echo "FANCY_MARKETPLACE_ID: ${FANCY_MARKETPLACE_ID}"
# Returns: urn:ngsi-ld:organization:30a8fd5c-02ab-4b07-b379-90e681fa3f78
```

### 5.4 List and Select Offering

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)
curl -s http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq .
```

Returns one offering: `M&P K8S Offering` (`urn:ngsi-ld:product-offering:35fdf42a-a903-4c0f-8934-2679312487b3`).

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)
export OFFER_ID=$(curl -s http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq '.[0].id' -r)
```

### 5.5 Order Placement & Completion

```bash
# Place order
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)
export ORDER_ID=$(curl -s -X POST http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{\"productOrderItem\":[{\"id\":\"random-order-id\",\"action\":\"add\",\"productOffering\":{\"id\":\"${OFFER_ID}\"}}],\"relatedParty\":[{\"id\":\"${FANCY_MARKETPLACE_ID}\"}]}" | jq '.id' -r)
echo "ORDER_ID: ${ORDER_ID}"
# Returns: urn:ngsi-ld:product-order:dbfce1b5-ceca-4a60-84da-e4d71e1765cc

# Complete order
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://fancy-marketplace.127.0.0.1.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)
curl -s -X PATCH http://fancy-marketplace.127.0.0.1.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder/${ORDER_ID} \
  -H 'Content-Type: application/json;charset=utf-8' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d '{"state":"completed"}' | jq '.state'
# Returns: "completed"
```

---

## 6. Phase 4: BAE Storefront Verification

**Status: Not yet tested.**

The FIWARE Business API Ecosystem (BAE) is deployed alongside the central profile (`provider-biz-ecosystem-logic-proxy`, `provider-biz-ecosystem-charging-backend` pods in provider namespace). To verify the graphical storefront:

1. Configure browser proxy to route through the local K3s squid proxy (`localhost:8888`)
2. Navigate to `https://marketplace.127.0.0.1.nip.io:8443/`
3. Visually confirm the M&P K8S Offering appears on the storefront GUI

---

## 7. Known Blocker: Contract Management Certificate Error

### 7.1 Symptom

After order completion, the operator token exchange still returns null:

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.127.0.0.1.nip.io:8080 $CONSUMER_OPERATOR_CREDENTIAL operator)
echo ${ACCESS_TOKEN}
# Returns: null
```

### 7.2 Root Cause

The **consumer's contract-management** pod (the marketplace's CM responsible for forwarding order events to the provider) crashes when attempting to handle TMForum notifications. The `Oid4VPClient` bean fails to instantiate because it cannot load TLS certificates:

```
java.lang.IllegalArgumentException: Was not able to load the certificates from /etc/ssl/cacert.pem
Caused by: java.security.cert.CertificateException: Missing input stream
```

The file `/etc/ssl/cacert.pem` exists (2004 bytes) but the Java certificate factory cannot parse it, likely due to a format or encoding issue in the certificate generated by the init containers.

**Impact:** The marketplace-to-provider notification chain is broken:

1. Consumer places order on central marketplace -- works
2. TMForum sends `ProductOrderStateChangeEvent` to consumer CM -- delivered
3. Consumer CM tries to authenticate with provider's verifier using MarketplaceCredential -- **crashes here**
4. Provider CM never receives the notification
5. TIR is never updated with OperatorCredential for `did:web:fancy-marketplace.biz`
6. Operator token exchange returns null

**Evidence:**

- Provider CM logs show only health checks and subscription registration, no order events received
- TIR entry for `did:web:fancy-marketplace.biz` shows `"attributes": []` (no OperatorCredential registered)
- Consumer CM logs show the full Java stack trace with certificate loading failure

### 7.3 Data-Plane Bypass (Workaround)

To verify the underlying data plane is functional independent of the broken contract management chain, Scorpio was accessed directly via port-forward:

```bash
# Find and tunnel to Scorpio
kubectl port-forward -n provider svc/data-service-scorpio 8889:9090 &
sleep 3

# Create K8SCluster entity directly in the broker
curl -i -X POST http://localhost:8889/ngsi-ld/v1/entities \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "urn:ngsi-ld:K8SCluster:cluster1",
    "type": "K8SCluster",
    "numNodes": {"type": "Property", "value": 3}
  }'
# Returns: HTTP/1.1 201 Created

# Verify retrieval
curl -s http://localhost:8889/ngsi-ld/v1/entities/urn:ngsi-ld:K8SCluster:cluster1 | jq .
# Returns: {"id": "urn:ngsi-ld:K8SCluster:cluster1", "type": "K8SCluster", "numNodes": {"type": "Property", "value": 3}}

# Cleanup
kill %1
```

**Result:** HTTP 201 Created -- confirming the data backend is fully functional. The blocker is isolated to the contract management notification chain, not the data plane.

---

## 8. Architectural Differences: Central vs MVD

| Aspect | Standard MVD | Central Marketplace |
|---|---|---|
| Marketplace role | Provider hosts its own TMForum | Neutral third-party orchestrator |
| TMForum API endpoint | `mp-tmf-api.127.0.0.1.nip.io` (provider-side) | `fancy-marketplace.127.0.0.1.nip.io` (consumer-side) |
| Contract management flow | Single CM on provider, direct TMForum events | Two CMs: marketplace CM authenticates with provider verifier and forwards events |
| Consumer credential format | Plain JWT (`user-credential`) | SD-JWT (`user-sd` with `vc+sd-jwt` format) |
| Provider registration | Not needed (provider owns the marketplace) | Provider registers as organization with `contractManagement` address |
| Policy for CM access | Not needed | `allowContractManagement.json` required on provider PAP |
| BAE storefront | Not deployed | Deployed (`provider-biz-ecosystem-logic-proxy`) |

---

## 9. Service Reference (Central Profile)

| Service | Namespace | Access |
|---|---|---|
| Central Marketplace TMForum | consumer | `http://fancy-marketplace.127.0.0.1.nip.io:8080` |
| Provider TMForum | provider | `http://tm-forum-api.127.0.0.1.nip.io:8080` |
| Provider Data Service (APISIX) | provider | `http://mp-data-service.127.0.0.1.nip.io:8080` |
| Provider Scorpio (direct) | provider | `kubectl port-forward svc/data-service-scorpio -n provider 8889:9090` |
| Provider ODRL PAP | provider | `http://pap-provider.127.0.0.1.nip.io:8080` |
| Consumer Keycloak | consumer | `https://keycloak-consumer.127.0.0.1.nip.io` (via proxy :8888) |
| Provider Keycloak | provider | `https://keycloak-provider.127.0.0.1.nip.io` (via proxy :8888) |
| Trust Anchor TIR | trust-anchor | `http://tir.127.0.0.1.nip.io:8080` |
| BAE Storefront | provider | `https://marketplace.127.0.0.1.nip.io:8443` |
| Contract Management (consumer) | consumer | `http://contract-management:8080` (cluster-internal) |
| Contract Management (provider) | provider | `http://contract-management.127.0.0.1.nip.io:8080` |
| Squid Proxy | infra | `localhost:8888` |

---

## 10. Demo Flow Summary

| Step | Status | Notes |
|---|---|---|
| Environment teardown (kill orphaned k3s) | Done | |
| `mvn clean deploy -Plocal,central` | Done | 09:27 min build |
| Central marketplace policies (5x) | Done | `prepare-central-market-policies.sh` |
| Provider contract management policy | Done | `allowContractManagement.json` |
| Provider credential issuance | Done | JWT with REPRESENTATIVE role |
| Provider registration on marketplace | Done | Includes contractManagement address |
| Product specification creation | Done | With credentialsConfig + policyConfig |
| Product offering creation | Done | M&P K8S Offering |
| Consumer user credential (SD-JWT) | Done | |
| Consumer operator credential | Done | |
| Pre-purchase: operator token returns null | Done | Expected |
| Consumer registration on marketplace | Done | |
| Offering listing verification | Done | Single offering visible |
| Order placement | Done | |
| Order completion | Done | `"state": "completed"` |
| Contract management notification to provider | **Blocked** | Consumer CM certificate loading error |
| Post-purchase: operator token exchange | **Blocked** | Returns null (TIR not updated) |
| BAE storefront verification | Not tested | |
| Data-plane bypass (Scorpio direct) | Done | 201 Created, entity retrievable |
# CENTRAL_MARKETPLACE.md Execution Session Log
> Session date: 2026-04-01. VM: 192.168.120.128, user `ben`, workdir `/fiware/data-space-connector`.

---

## What This Flow Is

CENTRAL_MARKETPLACE.md is the API-based flow where:
- `fancy-marketplace.biz` = the central marketplace (consumer side, runs consumer TMForum APIs)
- `mp-operations.org` = the provider (runs provider TMForum APIs + data service)
- A representative of the provider registers at the marketplace, creates offerings
- A representative of the consumer buys access via the marketplace's TMForum API
- On order completion, the consumer's `contract-management` notifies the provider's `contract-management`
- Provider's `contract-management` adds the consumer's DID to the TIL → OperatorCredential token works

**This is NOT DOME UI** — that's `MARKETPLACE_INTEGRATION.md`. This is pure TMForum API.

---

## Bugs Found and Fixed This Session

### Bug 1: Consumer `odrl-pap` version 1.2.0 — GraalVM SchemeRouter crash
- **Symptom:** All `POST /policy` calls return 500 with `SchemeRouter.defaultInstance() must not be used at build time`
- **Root cause:** GraalVM native image bug in odrl-pap 1.2.0
- **Fix:** `kubectl set image deployment/odrl-pap -n consumer odrl-pap=quay.io/fiware/odrl-pap:1.4.2`
- **Note:** Provider already had 1.4.2. Consumer was on 1.2.0.

### Bug 2: `prepare-central-market-policies.sh` uses hardcoded `127.0.0.1`
- **Symptom:** Script fails silently — posts to `pap-consumer.127.0.0.1.nip.io:8080` which is unreachable
- **Root cause:** Script hardcodes localhost instead of VM IP
- **Fix:** Post policies manually with correct IP (see commands below)
- **Note:** Deployment script Phase 6.8 already posts consumer policies correctly, so they were present

### Bug 3: Consumer `contract-management` 3.3.0 — Micronaut ResourceLoader can't read filesystem paths
- **Symptom:** `Resource not found: /signing-key/client-pkcs8.key.pem` despite file existing
- **Root cause:** GraalVM native image in 3.3.0 — Micronaut's ResourceLoader doesn't support `file:` or `file:///` filesystem paths
- **Fix:** Upgrade to `:latest` image (`quay.io/fiware/contract-management:latest`, already cached on node)
- **Workaround also tried:** Added `copy-signing-key` busybox init container to copy key to `/key-direct/` — this worked for file access but hit the next bug

### Bug 4: `signatureAlgorithm: ECDH-ES` in consumer contract-management ConfigMap
- **Symptom:** `Algorithm and key are not supported for signing JWTs` after upgrading to latest
- **Root cause:** Chart specifies `ECDH-ES` which is a key agreement algorithm, not a signing algorithm
- **Fix:** Patch ConfigMap to change to `ES256`
- **Note:** Due to iterative patching, `signatureAlgorithm` was accidentally renamed to `algorithm` and then went missing entirely. Ensure it reads `signatureAlgorithm: ES256`.

### Bug 5: `wistefan/oid4vp` library rejects PKCS8 EC key with ES256
- **Symptom:** `AuthorizationException: Algorithm and key are not supported for signing JWTs` even with ES256
- **Root cause:** The `wistefan/oid4vp` JWT signing library rejects PKCS8-wrapped EC keys (`BEGIN PRIVATE KEY`) for ES256. It expects raw EC format (`BEGIN EC PRIVATE KEY` = `client.key.pem`). However raw EC also fails with `algid parse error, not a sequence` when loaded as PKCS8.
- **Actual fix:** Disable OID4VP entirely — the provider's contract-management internal service (`contract-management.provider.svc.cluster.local:8080`) bypasses APISIX and does not require authentication
- **Fix:** Patch ConfigMap: `oid4vp:\n  enabled: false`

### Bug 6: Provider org `contractManagement.address` must use internal k8s URL
- **Symptom:** Consumer contract-management can't reach provider because `contract-management.192.168.120.128.nip.io:8080` requires APISIX auth (OID4VP)
- **Root cause:** CENTRAL_MARKETPLACE.md example uses the public external URL
- **Fix:** Register provider org with `address: http://contract-management.provider.svc.cluster.local:8080`
- **Note:** `tmf:update` action is NOT supported by odrl-pap. Had to create a new org instead of patching the existing one.

### Bug 7: Consumer `contract-management` `/listener/event` returns 404 in `latest` image
- **Symptom:** After disabling OID4VP, notifications arrive but return 404 on `/listener/event`
- **Root cause:** Unknown — the `latest` image may have changed the listener path, or the notification subscription isn't being registered (no "Attempting to register" log lines at all)
- **Status:** UNRESOLVED — consumer Keycloak went Pending (out of resources) before this could be debugged

### Bug 8: Consumer Keycloak went Pending after ~2 hours
- **Symptom:** `consumer-keycloak-0` status `Pending`, `get-credential` init container fails
- **Root cause:** Likely resource exhaustion on the VM after extended testing session
- **Fix needed:** Restart the VM or free resources, redeploy

---

## Completed Flow Steps

All commands below assume `cd /fiware/data-space-connector` and `IP=192.168.120.128`.

### Step 1: Post consumer PAP policies (if not already present)

```bash
# Check first
curl -s http://pap-consumer.${IP}.nip.io:8080/policy | python3 -m json.tool | grep "odrl:uid"

# If empty, post manually:
for policy in allowSelfRegistrationLegalPerson allowProductOrder allowProductOfferingCreation allowProductOffering allowProductSpec; do
  curl -s -X POST http://pap-consumer.${IP}.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d "$(cat ./it/src/test/resources/policies/${policy}.json)" | python3 -m json.tool | grep id
done
```

### Step 2: Verify consumer odrl-pap is 1.4.2

```bash
kubectl get deploy -n consumer odrl-pap -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should be: quay.io/fiware/odrl-pap:1.4.2
# If 1.2.0: kubectl set image deployment/odrl-pap -n consumer odrl-pap=quay.io/fiware/odrl-pap:1.4.2
```

### Step 3: Get provider credential and register provider org

```bash
export PROVIDER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-provider.${IP}.nip.io user-credential employee)

export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)

export MP_OPERATIONS_ID=$(curl -s -X POST \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/party/v4/organization \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{
      "name": "M&P Operations Org.",
      "partyCharacteristic": [
        {"name": "did", "value": "did:web:mp-operations.org"},
        {"name": "contractManagement", "value": {
          "address": "http://contract-management.provider.svc.cluster.local:8080",
          "clientId": "contract-management",
          "scope": ["external-marketplace"]
        }}
      ]
    }' | jq '.id' -r)
echo $MP_OPERATIONS_ID
```

**CRITICAL:** Use `contract-management.provider.svc.cluster.local:8080` (internal k8s), NOT the nip.io external URL.

### Step 4: Create product spec with credentialsConfig

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)

export PRODUCT_SPEC=$(curl -s -X POST \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/productSpecification \
    -H 'Content-Type: application/json;charset=utf-8' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d "{
      \"brand\": \"M&P Operations\",
      \"version\": \"1.0.0\",
      \"lifecycleStatus\": \"ACTIVE\",
      \"name\": \"M&P K8S\",
      \"relatedParty\": [{\"id\": \"${MP_OPERATIONS_ID}\", \"role\": \"provider\"}],
      \"productSpecCharacteristic\": [{
        \"id\": \"credentialsConfig\",
        \"name\": \"Credentials Config\",
        \"@schemaLocation\": \"https://raw.githubusercontent.com/FIWARE/contract-management/refs/heads/main/schemas/credentials/credentialConfigCharacteristic.json\",
        \"valueType\": \"credentialsConfiguration\",
        \"productSpecCharacteristicValue\": [{
          \"isDefault\": true,
          \"value\": {
            \"credentialsType\": \"OperatorCredential\",
            \"claims\": [{
              \"name\": \"roles\",
              \"path\": \"\$.roles[?(@.target==\\\"did:web:mp-operations.org\\\")].names[*]\",
              \"allowedValues\": [\"OPERATOR\"]
            }]
          }
        }]
      }]
    }" | jq '.id' -r)
echo $PRODUCT_SPEC
```

### Step 5: Create product offering

```bash
export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $PROVIDER_USER_CREDENTIAL default)

export OFFER_ID=$(curl -s -X POST \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
    -H 'Content-Type: application/json;charset=utf-8' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d "{
      \"version\": \"1.0.0\",
      \"lifecycleStatus\": \"ACTIVE\",
      \"name\": \"M&P K8S Offering\",
      \"productSpecification\": {\"id\": \"${PRODUCT_SPEC}\"}
    }" | jq '.id' -r)
echo $OFFER_ID
```

### Step 6: Register consumer org

```bash
export CONSUMER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${IP}.nip.io user-sd employee vc+sd-jwt)

export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)

export FANCY_MARKETPLACE_ID=$(curl -s -X POST \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/party/v4/organization \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{
      "name": "Fancy Marketplace Inc.",
      "partyCharacteristic": [{"name": "did", "value": "did:web:fancy-marketplace.biz"}]
    }' | jq '.id' -r)
echo $FANCY_MARKETPLACE_ID
```

### Step 7: Fix consumer contract-management

The consumer contract-management needs these fixes before it can process order notifications:

```bash
# 1. Upgrade image to latest (fixes ResourceLoader filesystem bug in 3.3.0)
kubectl set image deployment/contract-management -n consumer \
    contract-management=quay.io/fiware/contract-management:latest

# 2. Disable OID4VP (internal URL doesn't need auth, and oid4vp library has key compatibility bug)
kubectl get configmap -n consumer contract-management -o json | \
  python3 -c "
import json, sys
cm = json.load(sys.stdin)
yaml_str = cm['data']['application.yaml']
yaml_str = yaml_str.replace('oid4vp:\n  enabled: true', 'oid4vp:\n  enabled: false')
cm['data']['application.yaml'] = yaml_str
print(json.dumps(cm))
" | kubectl apply -f -

kubectl rollout restart deployment/contract-management -n consumer
kubectl rollout status deployment/contract-management -n consumer
```

### Step 8: Place and complete order

```bash
export CONSUMER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${IP}.nip.io user-sd employee vc+sd-jwt)

export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)

export ORDER_ID=$(curl -s -X POST \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d "{
      \"productOrderItem\": [{\"id\": \"order-1\", \"action\": \"add\",
        \"productOffering\": {\"id\": \"${OFFER_ID}\"}}],
      \"relatedParty\": [{\"id\": \"${FANCY_MARKETPLACE_ID}\"}]
    }" | jq '.id' -r)
echo $ORDER_ID

export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://fancy-marketplace.${IP}.nip.io:8080 $CONSUMER_USER_CREDENTIAL default)

curl -s -X PATCH \
    http://fancy-marketplace.${IP}.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder/${ORDER_ID} \
    -H 'Content-Type: application/json;charset=utf-8' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{"state": "completed"}' | jq .state
```

### Step 9: Verify TIL was updated (TODO — session ended before this)

```bash
# Check consumer contract-management logs
kubectl logs -n consumer deployment/contract-management --since=30s | \
    grep -v "health\|Health\|DEBUG\|hub\|Subscription" | tail -20

# Check TIL at provider
kubectl exec -n provider deployment/contract-management -- \
    wget -qO- "http://trusted-issuers-list:8080/v4/issuers" 2>/dev/null | \
    python3 -m json.tool | grep -A10 "fancy-marketplace"

# Verify OperatorCredential token works
export CONSUMER_OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${IP}.nip.io operator-credential operator)

export ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    http://mp-data-service.${IP}.nip.io:8080 $CONSUMER_OPERATOR_CREDENTIAL operator)
echo "Token: ${ACCESS_TOKEN:0:50}..."
```

---

## Remaining Issue: `/listener/event` 404 in `latest` image

After disabling OID4VP, order notifications reach the consumer contract-management but return 404 on `/listener/event`. Two possible causes:

1. The `latest` image changed the endpoint path (was `/listener/event`, may now be different)
2. The notification subscription is not being registered — no "Attempting to register" log lines seen

**To debug when VM is healthy again:**

```bash
# Check what endpoint the latest image exposes
kubectl logs -n consumer deployment/contract-management | grep -i "started\|route\|endpoint\|listener" | head -20

# Check what callback URL is registered in the TMForum hub
curl -s http://consumer-tm-forum-api-product-ordering-management.${IP}.nip.io:8080/tmf-api/productOrderingManagement/v4/hub

# Check the full application.yaml
kubectl get configmap -n consumer contract-management -o jsonpath='{.data.application\.yaml}'
```

---

## Current IDs (from this session — will be different after redeploy)

These IDs are from the current deployment and will change if the VM is redeployed:

| Resource | ID |
|----------|-----|
| Provider org (v1, wrong URL) | `urn:ngsi-ld:organization:6983b55f-137a-4cf7-b679-4681d88e8010` |
| Provider org (v2, correct internal URL) | `urn:ngsi-ld:organization:b681fe80-6463-47e9-9025-f6260471a015` |
| Product spec | `urn:ngsi-ld:product-specification:0b1f3409-9330-44aa-a2d7-fd7169c4176d` |
| Product offering | `urn:ngsi-ld:product-offering:ffc45721-bfac-4ee0-bbb0-d8a0636f2293` |
| Consumer org (fancy-marketplace) | `urn:ngsi-ld:organization:ef5c0bca-a63c-4414-acd6-a0217dfec2fb` |

---

## What Needs to Go into the Deployment Script

When the full flow is validated, these fixes should be automated in `fiware_deployment.sh`:

1. Patch consumer `odrl-pap` to `1.4.2` (same as provider)
2. Patch consumer `contract-management` image to `:latest`
3. Patch consumer `contract-management` ConfigMap: `oid4vp.enabled: false`
4. Register provider org at the marketplace with internal k8s contract-management URL

---

## Resource Exhaustion Note

The VM ran out of resources after ~2 hours of the session (consumer Keycloak went Pending). Before continuing, check:

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
free -h
df -h
```

If Keycloak is Pending due to Insufficient CPU/Memory, the VM may need a restart or some cleanup.

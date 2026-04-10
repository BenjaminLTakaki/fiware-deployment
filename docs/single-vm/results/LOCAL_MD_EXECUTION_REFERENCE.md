# LOCAL.MD Execution Reference

**Status: Fully tested and validated on 2026-03-31**
**Test environment:** Fontys NetLab VM — 192.168.120.128
**Script version:** v6.1

This document is a concise operational reference for running the LOCAL.MD use case (buy K8S cluster access via the FIWARE Data Space Connector marketplace) after a successful deployment with `fiware_deployment.sh`.

---

## 1. What the Deployment Script Automates

Running `./fiware_deployment.sh <IP>` fully handles the following infrastructure — no manual steps required for these:

| Phase | What is automated |
|-------|------------------|
| 6.7 | CCS configured: `data-service` scope maps `default` → UserCredential, `operator` → OperatorCredential, `legal` → LegalPersonCredential, `openid` → MembershipCredential |
| 6.7 | CCS configured: `tmf-marketplace` scope maps `default` → UserCredential |
| 6.7b | infra Traefik ConfigMap patched to add `ingressClass: traefik` under `kubernetesIngress`; traefik restarted — makes did:web domain ingresses routable (fixes VCVerifier/TIR lookup failures) |
| 6.8 | 7 baseline ODRL policies posted to PAP: EnergyReport read, productOffering read, organization self-register, productOrder create, K8SCluster read, allowContractManagement, **clusterCreate** |

After deployment, all infrastructure is ready. The manual steps below are the demo flow itself.

---

## 2. Manual Steps: Issue Credentials

Open a **new shell** after deployment so `~/.bashrc` loads `INTERNAL_IP`:

```bash
source ~/.bashrc
echo $INTERNAL_IP   # must print your VM IP, e.g. 192.168.120.128

export USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential employee)

export REP_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential representative)

export OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io operator-credential operator)
```

Keycloak users:

| Username | Credential type | Roles |
|----------|----------------|-------|
| employee | UserCredential | REPRESENTATIVE, READER, customer |
| representative | UserCredential | REPRESENTATIVE |
| operator | OperatorCredential | OPERATOR |

---

## 3. Manual Steps: Generate DID Certificate via did-helper

The consumer participant needs key material for signing Verifiable Presentations. Generate it:

```bash
mkdir -p cert && chmod o+rw cert
docker run -v $(pwd)/cert:/cert quay.io/fiware/did-helper:0.1.1
sudo chmod -R o+rw cert/private-key.pem

export HOLDER_DID=$(cat cert/did.json | jq '.id' -r)
echo "HOLDER_DID: ${HOLDER_DID}"
```

---

## 4. Manual Steps: Create Product Specs with Correct productSpecCharacteristic

This is the most critical manual step. The product specification **must** include the `credentialsConfig` characteristic. Without it, `contract-management` cannot determine what credential type to grant when the order completes, so the TIL entry is never added automatically and the buyer cannot authenticate.

### Correct productSpecCharacteristic format

```json
"productSpecCharacteristic": [
  {
    "name": "credentialsConfig",
    "productSpecCharacteristicValue": [
      {
        "isDefault": true,
        "value": {
          "credentialsType": "OperatorCredential",
          "credentialsConfig": {
            "OperatorCredential": {
              "clientId": "operator-credential",
              "trustedList": "http://trusted-issuers-list:8080",
              "paths": [
                {
                  "path": "$.roles[?(@.target==\"did:web:mp-operations.org\")].names[*]",
                  "allowedValues": ["OPERATOR"]
                }
              ]
            }
          }
        }
      }
    ]
  }
]
```

The JSONPath expression `$.roles[?(@.target=="did:web:mp-operations.org")].names[*]` matches the `OPERATOR` role scoped to the provider DID in the OperatorCredential issued by Keycloak. The `allowedValues: ["OPERATOR"]` must match exactly.

Create the product specification (always create catalog and category first, then spec, then offering):

```bash
# 1. Create product category
CATEGORY_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/category" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{"name":"K8S","lifecycleStatus":"Active"}' | jq -r '.id')

# 2. Create product catalog
CATALOG_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/catalog" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{"name":"K8S Catalog","lifecycleStatus":"Active","category":[{"id":"'$CATEGORY_ID'"}]}' \
    | jq -r '.id')

# 3. Create product specification (include productSpecCharacteristic as shown above)
PRODUCT_SPEC_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/productSpecification" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{ "name":"K8S Cluster Small", "lifecycleStatus":"Active", "productSpecCharacteristic": [ ... ] }' \
    | jq -r '.id')

# 4. Create product offering
PRODUCT_OFFERING_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{ "name":"K8S Cluster Small Offer", "lifecycleStatus":"Active",
          "productSpecification":{"id":"'$PRODUCT_SPEC_ID'"},
          "catalog":{"id":"'$CATALOG_ID'"} }' \
    | jq -r '.id')
```

---

## 5. Manual Steps: Register as Customer and Place Order

```bash
export PROVIDER_DID="did:web:mp-operations.org"
export CONSUMER_DID="did:web:fancy-marketplace.biz"

# Register organization (self-registration)
FANCY_MARKETPLACE_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/party/v4/organization" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{"name":"Fancy Marketplace Inc.",
         "partyCharacteristic":[{"name":"did","value":"'$CONSUMER_DID'"}]}' \
    | jq -r '.id')

# Place order
ORDER_ID=$(curl -s -X POST \
    "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $REP_CREDENTIAL" \
    -d '{
      "productOrderItem": [{
        "id": "1",
        "action": "add",
        "productOffering": {"id": "'$PRODUCT_OFFERING_ID'"}
      }],
      "relatedParty": [{"id": "'$FANCY_MARKETPLACE_ID'", "role": "buyer"}]
    }' | jq -r '.id')

# Poll order status until COMPLETED
curl -s "http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder/$ORDER_ID" \
    -H "Authorization: Bearer $REP_CREDENTIAL" | jq '.state'
```

When the order reaches `COMPLETED`, `contract-management` automatically adds the consumer DID to TIL with OperatorCredential (provided the product spec has the correct `productSpecCharacteristic`).

---

## 6. Manual Steps: Create K8SCluster Entity

```bash
# Get operator access token via OID4VP
ACCESS_TOKEN=$(./doc/scripts/get_access_token_oid4vp.sh \
    "http://mp-data-service.${INTERNAL_IP}.nip.io:8080" \
    "$OPERATOR_CREDENTIAL" operator)

# POST K8SCluster entity
curl -s -X POST \
    "http://mp-data-service.${INTERNAL_IP}.nip.io:8080/ngsi-ld/v1/entities" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d '{
      "id": "urn:ngsi-ld:K8SCluster:my-cluster",
      "type": "K8SCluster",
      "name": {"type": "Property", "value": "my-cluster"}
    }'
```

---

## 7. TIL Entry: Automatic vs Manual

When an order reaches `COMPLETED`, `contract-management` automatically adds the buyer DID to TIL **if and only if** the product specification includes a properly formed `productSpecCharacteristic` with `credentialsConfig`.

If the product spec is missing that characteristic, add the TIL entry manually:

```bash
curl -s -X PUT \
    "http://trusted-issuers-list.${INTERNAL_IP}.nip.io:8080/issuer/${CONSUMER_DID}" \
    -H "Content-Type: application/json" \
    -d '{
      "did": "'$CONSUMER_DID'",
      "credentials": [{
        "credentialsType": "OperatorCredential",
        "claims": [{"name": "roles", "allowedValues": ["OPERATOR"]}]
      }]
    }'
```

Verify the entry was added:

```bash
curl -s "http://trusted-issuers-list.${INTERNAL_IP}.nip.io:8080/issuer/${CONSUMER_DID}" | jq .
```

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| VCVerifier returns 500 on `/services/data-service/token` | TIL has no OperatorCredential entry for the buyer DID | Check `curl http://trusted-issuers-list.${INTERNAL_IP}.nip.io:8080/issuer/<DID>`. If missing, use the manual TIL PUT above |
| POST `/ngsi-ld/v1/entities` returns 403 for K8SCluster | clusterCreate policy missing from PAP | Check `curl http://pap-provider.${INTERNAL_IP}.nip.io:8080/policy | jq '.[]["odrl:uid"]'`. If `clusterCreate` is absent, post it: `curl -X POST http://pap-provider.${INTERNAL_IP}.nip.io:8080/policy -H 'Content-Type: application/json' -d @data-space-connector/it/src/test/resources/policies/clusterCreate.json` |
| `get_access_token_oid4vp.sh` returns `null` for operator scope | CCS `operator` scope not configured | Check `curl http://provider-ccs.${INTERNAL_IP}.nip.io:8080/service/data-service`. If `operator` scope is missing, re-run Phase 6.7 manually |
| did:web domain returns connection refused or NXDOMAIN | infra Traefik not routing `ingressClassName: traefik` ingresses | Check `kubectl get cm traefik-config -n infra -o yaml`. If `kubernetesIngress: {}` (no ingressClass key), patch manually: `kubectl patch cm traefik-config -n infra --type merge -p '{"data":{"traefik.yaml":"..."}}' && kubectl rollout restart deployment/traefik -n infra` |
| Order stays in `ACKNOWLEDGED` / `IN_PROGRESS` forever | contract-management cannot reach provider callback, or product spec missing `productSpecCharacteristic` | Check `kubectl logs -n provider deployment/contract-management`. Verify product spec has `credentialsConfig` characteristic |
| TMForum POST offering returns 400 | Required reference fields missing | Create in order: category → catalog → productSpecification → productOffering. Never skip steps |

---

## 9. Key Endpoints

| Service | URL |
|---------|-----|
| TIR | `http://tir.${INTERNAL_IP}.nip.io:8080/v4/issuers` |
| TIL | `http://trusted-issuers-list.${INTERNAL_IP}.nip.io:8080/issuer` |
| PAP | `http://pap-provider.${INTERNAL_IP}.nip.io:8080/policy` |
| CCS | `http://provider-ccs.${INTERNAL_IP}.nip.io:8080/service` |
| Data Service | `http://mp-data-service.${INTERNAL_IP}.nip.io:8080` |
| TMForum API | `http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080` |
| Keycloak Consumer | `https://keycloak-consumer.${INTERNAL_IP}.nip.io` |
| Scorpio Provider | `http://scorpio-provider.${INTERNAL_IP}.nip.io:8080` |

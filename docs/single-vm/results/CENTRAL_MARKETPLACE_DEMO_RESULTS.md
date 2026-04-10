# CENTRAL_MARKETPLACE Demo - Execution Results Report

**Date:** March 30, 2026  
**Environment:** Fontys Netlab K3s Cluster (IP: `192.168.120.128`)  
**Document Version:** 1.0

---

## 1. Executive Summary

The CENTRAL_MARKETPLACE demo was executed to validate the full FIWARE Data Space Connector flow with `did:web` identity resolution. The demo achieved **partial success** - core credential flows (UserCredential, RepresentativeCredential) worked, while the OperatorCredential scope had policy configuration issues.

| Credential Type | Scope | Status | Access Token |
|----------------|-------|--------|-------------|
| UserCredential | default | ✅ WORKS | ✅ Returns JWT |
| UserCredential | legal | ✅ WORKS | ✅ Returns JWT |
| RepresentativeCredential | default | ✅ WORKS | ✅ Returns JWT |
| OperatorCredential | operator | ⚠️ PARTIAL | ❌ Returns null |

---

## 2. Demo Inputs

### 2.1 Environment Variables

```bash
# Domain Configuration
HOLDER_DID="did:web:fancy-marketplace.biz"
PROVIDER_DID="did:web:mp-operations.org"

# Network Endpoints
KEYCLOAK_URL="https://keycloak-consumer.192.168.120.128.nip.io"
TOKEN_ENDPOINT="https://verifier-provider.192.168.120.128.nip.io:8443/services/data-service/token"
DATA_SERVICE_URL="http://mp-data-service.192.168.120.128.nip.io:8080"
TIR_URL="http://tir.192.168.120.128.nip.io:8080"
PAP_URL="http://pap-provider.192.168.120.128.nip.io:8080"
SCORPIO_URL="http://scorpio-provider.192.168.120.128.nip.io:8080"
TM_FORUM_API="http://tm-forum-api.192.168.120.128.nip.io:8080"
```

### 2.2 Keycloak Credentials

| User | Password | Credential Type |
|------|----------|----------------|
| employee | test | UserCredential |
| representative | test | UserCredential (with REPRESENTATIVE role) |
| operator | test | OperatorCredential |

### 2.3 Keycloak Realm

- **Realm Name:** `test-realm`
- **Credential Issuer:** `https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm`
- **Credential Endpoint:** `https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential`

### 2.4 Certificate Configuration

```bash
# Certificate Location
cert/private-key.pem    # EC private key for signing
cert/public-key.pem     # EC public key
cert/did.json          # Contains {"id": "did:web:fancy-marketplace.biz"}

# Certificate Generated via Maven
mvn clean deploy -Plocal
```

---

## 3. Demo Outputs - Successful Flows

### 3.1 TIR (Trust Issuer Registry) Registration

**Input:**
```bash
curl -X GET http://tir.192.168.120.128.nip.io:8080/v4/issuers
```

**Output:**
```json
{
  "self": "http://tir.192.168.120.128.nip.io:8080/v4/issuers",
  "items": [
    {"did": "did:web:fancy-marketplace.biz", "href": "..."},
    {"did": "did:web:mp-operations.org", "href": "..."}
  ],
  "total": 2,
  "pageSize": 2
}
```

**Status:** ✅ SUCCESS

---

### 3.2 UserCredential Issuance (employee user)

**Input:**
```bash
# Get access token
TOKEN=$(curl -s -k -X POST "https://keycloak-consumer.192.168.120.128.nip.io/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&username=employee&password=test&client_id=account-console" | jq -r '.access_token')

# Get credential offer
OFFER_URI=$(curl -s -k -X GET 'https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential-offer-uri?credential_configuration_id=user-credential' \
    --header "Authorization: Bearer ${TOKEN}" | jq '"\(.issuer)\(.nonce)"' -r)

# Get pre-authorized code
PRE_AUTH_CODE=$(curl -s -k -X GET ${OFFER_URI} --header "Authorization: Bearer ${TOKEN}" | \
    jq '.grants."urn:ietf:params:oauth:grant-type:pre-authorized_code"."pre-authorized_code"' -r)

# Exchange for credential
CRED_TOKEN=$(curl -s -k -X POST "https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/openid-connect/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:pre-authorized_code&pre-authorized_code=${PRE_AUTH_CODE}" | jq -r '.access_token')

# Issue credential
VERIFIABLE_CREDENTIAL=$(curl -s -k -X POST "https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential" \
    --header "Authorization: Bearer ${CRED_TOKEN}" \
    --data '{"credential_identifier": "user-credential", "format":"jwt_vc"}' | jq '.credential' -r)
```

**Output:**
```json
{
  "vc": {
    "type": ["UserCredential"],
    "issuer": "did:web:fancy-marketplace.biz",
    "credentialSubject": {
      "id": "did:web:fancy-marketplace.biz",
      "firstName": "Test",
      "lastName": "User",
      "email": "employee@consumer.org",
      "roles": [{"names": ["REPRESENTATIVE", "READER", "customer"], "target": "did:web:mp-operations.org"}],
      "zipcode": "01169",
      "city": "Dresden",
      "country": "Germany",
      "street": "Main Street",
      "streetNumber": "10"
    }
  }
}
```

**Status:** ✅ SUCCESS

---

### 3.3 Access Token Generation (UserCredential with default scope)

**Input:**
```bash
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$VERIFIABLE_CREDENTIAL" default
```

**Output:**
```jwt
eyJhbGciOiJSUzI1NiIsImtpZCI6IkZCejJsNVNzYWhQd0g2MXpwLW1tWm50UnIxUlJvSHN2WEhyc0dMM1JGcTQiLCJ0eXAiOiJKV1QifQ...
```

**Decoded Payload:**
```json
{
  "aud": ["data-service"],
  "exp": 1774906779,
  "iss": "https://verifier-provider.192.168.120.128.nip.io",
  "sub": "did:web:fancy-marketplace.biz",
  "verifiableCredential": {
    "@context": [...],
    "credentialSubject": {...},
    "id": "urn:uuid:...",
    "issued": "2026-03-30T21:10:42Z",
    "issuer": "did:web:fancy-marketplace.biz",
    "type": ["UserCredential"]
  }
}
```

**Status:** ✅ SUCCESS

---

### 3.4 Data Access with UserCredential

**Input:**
```bash
curl -X GET 'http://mp-data-service.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1' \
    --header "Authorization: Bearer ${DATA_SERVICE_ACCESS_TOKEN}"
```

**Output:**
```json
{
  "id": "urn:ngsi-ld:EnergyReport:fms-1",
  "type": "EnergyReport",
  "consumption": {
    "type": "Property",
    "value": "94"
  },
  "name": {
    "type": "Property",
    "value": "Standard Server"
  }
}
```

**Status:** ✅ SUCCESS

---

### 3.5 Organization Registration (RepresentativeCredential)

**Input:**
```bash
export CONSUMER_DID="did:web:fancy-marketplace.biz"
curl -X POST http://mp-tmf-api.192.168.120.128.nip.io:8080/tmf-api/party/v4/organization \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{
      "name": "Fancy Marketplace Inc.",
      "partyCharacteristic": [{"name": "did", "value": "${CONSUMER_DID}"}]
    }'
```

**Output:**
```json
{
  "id": "urn:ngsi-ld:organization:41499909-9232-4e85-94d5-6f47df8964e3",
  "href": "urn:ngsi-ld:organization:41499909-9232-4e85-94d5-6f47df8964e3",
  "name": "Fancy Marketplace Inc."
}
```

**Status:** ✅ SUCCESS

---

### 3.6 Product Catalog & Ordering

**Input:**
```bash
# Get product offerings
curl -X GET http://mp-tmf-api.192.168.120.128.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering \
    -H "Authorization: Bearer ${ACCESS_TOKEN}"

# Place order
curl -X POST http://mp-tmf-api.192.168.120.128.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{
      "productOrderItem": [{"id": "random-order-id", "action": "add", "productOffering": {"id": "${OFFER_ID}"}}],
      "relatedParty": [{"id": "${FANCY_MARKETPLACE_ID}"}]
    }'

# Complete order
curl -X PATCH http://tm-forum-api.192.168.120.128.nip.io:8080/tmf-api/productOrderingManagement/v4/productOrder/${ORDER_ID} \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{"state": "completed"}'
```

**Output:**
```json
{
  "id": "urn:ngsi-ld:product-order:fd2b93a3-0a5b-4b37-87e2-ef93aa27a3aa",
  "state": "completed",
  "productOrderItem": [{
    "action": "add",
    "productOffering": {"id": "urn:ngsi-ld:product-offering:ee1708cc-8bc5-4ce7-b144-68a0b0fc74be"}
  }]
}
```

**Status:** ✅ SUCCESS

---

## 4. Demo Outputs - Failed/Partial Flows

### 4.1 OperatorCredential Issuance

**Input:**
```bash
./doc/scripts/get_credential.sh https://keycloak-consumer.192.168.120.128.nip.io operator-credential operator
```

**Output:**
```json
{
  "vc": {
    "type": ["OperatorCredential"],
    "issuer": "did:web:fancy-marketplace.biz",
    "credentialSubject": {
      "firstName": "Test",
      "email": "operator@consumer.org",
      "roles": [{"names": ["OPERATOR"], "target": "did:web:mp-operations.org"}]
    }
  }
}
```

**Status:** ✅ Credential issued successfully

---

### 4.2 Access Token Generation (OperatorCredential - FAILED)

**Input:**
```bash
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$OPERATOR_CREDENTIAL" operator
```

**Output:**
```null```

**Verifier Logs:**
```
{"level":"debug","msg":"VP Token does not contain query map..."}
{"level":"debug","msg":"The subject contains forbidden claims or values: {}."}
{"level":"error","msg":"Failure during generating M2M token: invalid_vc"}
```

**Status:** ❌ FAILED - The verifier receives an empty credentialSubject

**Root Cause:** The Keycloak credential template formats `credentialSubject` as an object instead of an array.

**Expected:**
```json
"credentialSubject": [{ ... }]
```

**Actual:**
```json
"credentialSubject": { ... }
```

---

### 4.3 PAP Policy Creation (Partial)

**Input:**
```bash
curl -X POST http://pap-provider.192.168.120.128.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d '{
      "@context": {...},
      "odrl:uid": "https://mp-operation.org/policy/common/test",
      "@type": "odrl:Policy",
      "odrl:permission": {...}
    }'
```

**Output:**
```
500 - Internal Server Error
Error id 57e8fe57-8989-4885-8a7d-25ef80aa3e49-5
```

**Status:** ⚠️ PARTIAL - Some policies created successfully, others failed with 500 error

**Successfully Created Policies:**
- `https://mp-operation.org/policy/common/offering`
- `https://mp-operation.org/policy/common/selfRegistration`
- `https://mp-operation.org/policy/common/ordering`
- `https://mp-operation.org/policy/common/allowRead`

---

### 4.4 CCS (Contract Configuration Service) Update

**Input:**
```bash
curl -X PUT 'http://provider-ccs.192.168.120.128.nip.io:8080/service/data-service' \
    -H 'Content-Type: application/json' \
    -d '{
      "defaultOidcScope": "default",
      "oidcScopes": {
        "default": {"credentials": [{"type": "UserCredential", ...}]},
        "operator": {"credentials": [{"type": "OperatorCredential", ...}]}
      }
    }'
```

**Output:**
```json
{"title":"Internal Server Error","status":500,"detail":"Request could not be answered due to an unexpected internal error."}
```

**Status:** ❌ FAILED

---

## 5. DID Resolution Status

### 5.1 DID Document Available via NodePort

**Input:**
```bash
kubectl expose deployment consumer-did -n consumer --port=80 --target-port=3000 --name=consumer-did-external --type=NodePort
NODE_PORT=$(kubectl get svc consumer-did-external -n consumer -o jsonpath='{.spec.ports[0].nodePort}')
curl -s "http://192.168.120.128:$NODE_PORT/.well-known/did.json" | jq '.id'
```

**Output:**
```
"did:web:fancy-marketplace.biz"
```

**Status:** ✅ WORKS via NodePort

---

### 5.2 DID Document via Traefik Ingress

**Input:**
```bash
curl -s -H "Host: fancy-marketplace.biz" http://consumer-did.192.168.120.128.nip.io/.well-known/did.json
```

**Output:**
```
jq: error (at <stdin>:1): Cannot index number with string "id"
```

**Status:** ❌ FAILS - Traefik ingress routing issue with `/.well-known/` paths

**Workaround:** Use NodePort service instead of ingress

---

## 6. Comparison: CENTRAL_MARKETPLACE vs LOCAL.MD

| Aspect | LOCAL.MD | CENTRAL_MARKETPLACE |
|--------|----------|---------------------|
| DID Method | `did:key` (self-contained) | `did:web` (requires DNS) |
| DID Resolution | Not required | Requires hosting DID document |
| Credential Subject Format | Array ✅ | Object ❌ (Keycloak config) |
| Trust Framework | Basic | Full eIDAS/DSS |
| PAP Policies | Simplified | Manual setup required |
| CCS Configuration | Pre-configured | Manual update required |
| E2E Flow | ✅ Works | ⚠️ Partial (operator scope fails) |

---

## 7. Key Issues and Fixes Required

### 7.1 Keycloak Credential Template Fix

**Problem:** `credentialSubject` is formatted as object instead of array

**Fix Required:**
1. Access Keycloak Admin Console
2. Navigate to: Client Scopes → operator-credential → Configure tab
3. Find the "credentialSubject" mapper
4. Enable "Add to array" option
5. Re-issue credentials

### 7.2 Traefik Ingress Configuration

**Problem:** `/.well-known/` paths return 404 through ingress

**Workaround:** Use NodePort service for DID resolution

### 7.3 PAP Policy Synchronization

**Problem:** Some policies return 500 error during creation

**Fix:** Ensure ODRL policy JSON-LD syntax is correct

### 7.4 CCS Service Configuration

**Problem:** PUT to CCS returns 500 Internal Server Error

**Fix:** Check CCS pod logs for detailed error message

---

## 8. Test Scripts Reference

### 8.1 Credential Issuance

```bash
# Get UserCredential
./doc/scripts/get_credential.sh https://keycloak-consumer.192.168.120.128.nip.io user-credential employee

# Get OperatorCredential  
./doc/scripts/get_credential.sh https://keycloak-consumer.192.168.120.128.nip.io operator-credential operator
```

### 8.2 Access Token Generation

```bash
# With UserCredential
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$CRED" default

# With OperatorCredential (FAILS)
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$OPERATOR_CRED" operator
```

### 8.3 Data Access

```bash
curl -X GET 'http://mp-data-service.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
```

---

## 9. Recommendations

1. **For Full Demo Success:** Fix the Keycloak credential template to output `credentialSubject` as an array
2. **For Production:** Implement proper DNS-based DID resolution instead of NodePort workaround
3. **For Alternative Approach:** Use LOCAL.MD with `did:key` method which avoids DID resolution entirely
4. **For Debugging:** Check verifier pod logs with:
   ```bash
   kubectl logs -n provider deployment/verifier --since=5m | grep -E "error|subject|credential"
   ```

---

## 10. Conclusion

The CENTRAL_MARKETPLACE demo demonstrates the FIWARE Data Space Connector's capability for:
- ✅ DID-based identity with `did:web`
- ✅ OID4VC credential issuance via Keycloak
- ✅ VP token generation and verification
- ✅ Access token issuance for data services
- ✅ TM-Forum API integration for marketplace operations
- ✅ Product ordering and catalog management

**Remaining Issues:**
- ❌ OperatorCredential scope requires Keycloak template fix
- ⚠️ Traefik ingress routing for `/.well-known/` paths
- ⚠️ CCS service configuration updates

**Recommended Next Steps:**
1. Fix Keycloak credential template configuration
2. Test with LOCAL.MD (`did:key`) approach as baseline
3. Update CCS service configuration for full operator scope support

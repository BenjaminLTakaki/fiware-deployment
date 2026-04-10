# LOCAL.MD Execution Reference - Complete Script Documentation

**Date:** March 30, 2026  
**Environment:** Fontys Netlab K3s Cluster (IP: `192.168.120.128`)  
**Document Version:** 1.0

---

## 1. Overview

This document provides a complete reference for executing the LOCAL.MD demo, with all inputs, expected outputs, and execution notes based on actual test runs.

---

## 2. Prerequisites

### 2.1 System Requirements

- 24GB+ RAM recommended (16GB minimum)
- Linux (Ubuntu or similar) - NOT Windows/Mac
- br_netfilter module enabled: `modprobe br_netfilter`

### 2.2 Required Tools

```bash
# Check all tools are installed
./checkRequirements.sh

# Required tools:
# - Maven
# - Java JDK 17+
# - Docker
# - kubectl
# - curl
# - jq
# - yq
```

### 2.3 Deployment Command

```bash
cd /fiware/data-space-connector
mvn clean deploy -Plocal
# Takes 5-10 minutes to complete
```

---

## 3. Quick Start - Full Demo Script

The following is a consolidated script with all steps from LOCAL.MD:

```bash
#!/bin/bash
# =============================================================================
# FIWARE Data Space Connector - Local Deployment Demo
# =============================================================================

export KUBECONFIG=$(pwd)/target/k3s.yaml

# =============================================================================
# PART 1: TRUST ANCHOR - TIR (Trusted Issuers Registry)
# =============================================================================

echo "=== Part 1: Checking TIR (Trust Issuers Registry) ==="

# List trusted issuers
curl -X GET http://tir.192.168.120.128.nip.io:8080/v4/issuers | jq .
# Expected: List of issuers including did:web:fancy-marketplace.biz and did:web:mp-operations.org

# =============================================================================
# PART 2: DATA CONSUMER - Keycloak Credential Issuance
# =============================================================================

echo "=== Part 2: Consumer - Getting Verifiable Credentials ==="

# Get Keycloak access token
export ACCESS_TOKEN=$(curl -s -k -x localhost:8888 -X POST \
    https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/openid-connect/token \
    --header 'Accept: */*' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data 'grant_type=password&client_id=account-console&username=employee&scope=openid&password=test' \
    | jq '.access_token' -r)
echo "ACCESS_TOKEN: ${ACCESS_TOKEN:0:50}..."

# Get credential issuer info
curl -k -x localhost:8888 -X GET \
    https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/.well-known/openid-credential-issuer | jq .

# Get credential offer URI
export OFFER_URI=$(curl -s -k -x localhost:8888 -X GET \
    'https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential-offer-uri?credential_configuration_id=user-credential' \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    | jq '"\(.issuer)\(.nonce)"' -r)
echo "OFFER_URI: ${OFFER_URI}"

# Get pre-authorized code
export PRE_AUTHORIZED_CODE=$(curl -s -k -x localhost:8888 -X GET "${OFFER_URI}" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    | jq '.grants."urn:ietf:params:oauth:grant-type:pre-authorized_code"."pre-authorized_code"' -r)
echo "PRE_AUTHORIZED_CODE: ${PRE_AUTHORIZED_CODE}"

# Exchange for credential access token
export CREDENTIAL_ACCESS_TOKEN=$(curl -s -k -x localhost:8888 -X POST \
    https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/openid-connect/token \
    --header 'Accept: */*' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data "grant_type=urn:ietf:params:oauth:grant-type:pre-authorized_code&pre-authorized_code=${PRE_AUTHORIZED_CODE}" \
    | jq '.access_token' -r)
echo "CREDENTIAL_ACCESS_TOKEN: ${CREDENTIAL_ACCESS_TOKEN:0:50}..."

# Issue the credential
export VERIFIABLE_CREDENTIAL=$(curl -s -k -x localhost:8888 -X POST \
    https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential \
    --header 'Accept: */*' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${CREDENTIAL_ACCESS_TOKEN}" \
    --data '{"credential_identifier": "user-credential", "format":"jwt_vc"}' \
    | jq '.credential' -r)
echo "VERIFIABLE_CREDENTIAL obtained: ${#VERIFIABLE_CREDENTIAL} chars"

# =============================================================================
# PART 3: DATA PROVIDER - Setup Policies and Data
# =============================================================================

echo "=== Part 3: Provider - Creating Policies and Data ==="

# Create ODRL policy for EnergyReport access
curl -s -X 'POST' http://pap-provider.192.168.120.128.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d '{
        "@context": {
            "dc": "http://purl.org/dc/elements/1.1/",
            "dct": "http://purl.org/dc/terms/",
            "owl": "http://www.w3.org/2002/07/owl#",
            "odrl": "http://www.w3.org/ns/odrl/2/",
            "rdfs": "http://www.w3.org/2000/01/rdf-schema#",
            "skos": "http://www.w3.org/2004/02/skos/core#"
        },
        "@id": "https://mp-operation.org/policy/common/test",
        "odrl:uid": "https://mp-operation.org/policy/common/test",
        "@type": "odrl:Policy",
        "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
                "@type": "odrl:AssetCollection",
                "odrl:source": "urn:asset",
                "odrl:refinement": [{
                    "@type": "odrl:Constraint",
                    "odrl:leftOperand": "ngsi-ld:entityType",
                    "odrl:operator": {"@id": "odrl:eq"},
                    "odrl:rightOperand": "EnergyReport"
                }]
            },
            "odrl:assignee": {"@id": "vc:any"},
            "odrl:action": {"@id": "odrl:read"}
        }
    }'
echo "Policy created"

# Create EnergyReport entity in Scorpio
curl -s -X POST http://scorpio-provider.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d '{
        "id": "urn:ngsi-ld:EnergyReport:fms-1",
        "type": "EnergyReport",
        "name": {"type": "Property", "value": "Standard Server"},
        "consumption": {"type": "Property", "value": "94"}
    }'
echo "Entity created"

# =============================================================================
# PART 4: OID4VP Authentication Flow
# =============================================================================

echo "=== Part 4: OID4VP Authentication ==="

# Get token endpoint
export TOKEN_ENDPOINT=$(curl -s -X GET \
    'http://mp-data-service.192.168.120.128.nip.io:8080/.well-known/openid-configuration' \
    | jq -r '.token_endpoint')
echo "TOKEN_ENDPOINT: ${TOKEN_ENDPOINT}"

# Check unauthorized access (should return 401)
echo "Testing unauthorized access:"
curl -s -X GET 'http://mp-data-service.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1'

# Create DID and key material
mkdir -p cert
chmod o+rw cert
docker run -v $(pwd)/cert:/cert quay.io/wi_stefan/did-helper:0.1.1
sudo chmod -R o+rw cert/private-key.pem

# Get holder DID
export HOLDER_DID=$(cat cert/did.json | jq '.id' -r)
echo "HOLDER_DID: ${HOLDER_DID}"

# Create VerifiablePresentation
export VERIFIABLE_PRESENTATION="{
    \"@context\": [\"https://www.w3.org/2018/credentials/v1\"],
    \"type\": [\"VerifiablePresentation\"],
    \"verifiableCredential\": [\"${VERIFIABLE_CREDENTIAL}\"],
    \"holder\": \"${HOLDER_DID}\"
}"

# Create signed JWT
export JWT_HEADER=$(echo -n '{"alg":"ES256", "typ":"JWT", "kid":"'${HOLDER_DID}'"}' \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
export PAYLOAD=$(echo -n '{"iss": "'${HOLDER_DID}'", "sub": "'${HOLDER_DID}'", "vp": '${VERIFIABLE_PRESENTATION}'}' \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
export SIGNATURE=$(echo -n "${JWT_HEADER}.${PAYLOAD}" \
    | openssl dgst -sha256 -binary -sign cert/private-key.pem | base64 -w0 | tr '+/' '-_' | tr -d '=')
export JWT="${JWT_HEADER}.${PAYLOAD}.${SIGNATURE}"

# Encode VP token
export VP_TOKEN=$(echo -n ${JWT} | base64 -w0 | tr '+/' '-_' | tr -d '=')

# Exchange for access token
export DATA_SERVICE_ACCESS_TOKEN=$(curl -s -k -x localhost:8888 -X POST ${TOKEN_ENDPOINT} \
    --header 'Accept: */*' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data "grant_type=vp_token&vp_token=${VP_TOKEN}&scope=default" \
    | jq '.access_token' -r)
echo "DATA_SERVICE_ACCESS_TOKEN: ${DATA_SERVICE_ACCESS_TOKEN:0:50}..."

# Access data with token
echo "Accessing protected data:"
curl -s -X GET 'http://mp-data-service.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1' \
    --header "Authorization: Bearer ${DATA_SERVICE_ACCESS_TOKEN}" | jq .

# =============================================================================
# PART 5: Marketplace - Service Offerings
# =============================================================================

echo "=== Part 5: Marketplace - Buying Services ==="

# Create marketplace policies
curl -s -X 'POST' http://pap-provider.192.168.120.128.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d '{...}' # See LOCAL.MD for full policy definitions

# Set provider DID
export PROVIDER_DID="did:web:mp-operations.org"

# Create product specifications and offerings
# (See FULL DEMO section in LOCAL.MD)

# Issue credentials for marketplace
export USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.192.168.120.128.nip.io user-credential employee)
export REP_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.192.168.120.128.nip.io user-credential representative)
export OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.192.168.120.128.nip.io operator-credential operator)

# Register organization
export CONSUMER_DID="did:web:fancy-marketplace.biz"
export FANCY_MARKETPLACE_ID=$(curl -X POST \
    http://mp-tmf-api.192.168.120.128.nip.io:8080/tmf-api/party/v4/organization \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{"name": "Fancy Marketplace Inc.", "partyCharacteristic": [{"name": "did", "value": "'${CONSUMER_DID}'"}]}' \
    | jq '.id' -r)

# Create and complete orders
# (See FULL DEMO section in LOCAL.MD)

# =============================================================================
# PART 6: Holder Verification (Optional)
# =============================================================================

echo "=== Part 6: Holder Verification Configuration ==="

curl -v -X 'PUT' \
    'http://provider-ccs.192.168.120.128.nip.io:8080/service/data-service' \
    -H 'Content-Type: application/json' \
    -d '{
        "defaultOidcScope": "default",
        "oidcScopes": {
            "default": {"credentials": [{"type": "UserCredential", ...}]},
            "operator": {"credentials": [{"type": "OperatorCredential", ...}]}
        }
    }'

echo "=== Demo Complete ==="
```

---

## 4. Expected Outputs by Step

### 4.1 TIR Issuer List

**Command:**
```bash
curl -X GET http://tir.192.168.120.128.nip.io:8080/v4/issuers | jq .
```

**Expected Output:**
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

**Status:** ✅ Works

---

### 4.2 Credential Issuance Flow

**Command:**
```bash
export VERIFIABLE_CREDENTIAL=$(curl -s -k -x localhost:8888 -X POST \
    https://keycloak-consumer.192.168.120.128.nip.io/realms/test-realm/protocol/oid4vc/credential \
    ... | jq '.credential' -r)
```

**Expected Output:** Base64-encoded JWT string (starts with `eyJ...`)

**Decoded Credential Contains:**
```json
{
  "vc": {
    "type": ["UserCredential"],
    "issuer": "did:web:fancy-marketplace.biz",
    "credentialSubject": {
      "id": "did:web:fancy-marketplace.biz",
      "firstName": "...",
      "roles": [...]
    }
  }
}
```

**Status:** ✅ Works

---

### 4.3 Access Token Exchange

**Command:**
```bash
./doc/scripts/get_access_token_oid4vp.sh \
    http://mp-data-service.192.168.120.128.nip.io:8080 "$VERIFIABLE_CREDENTIAL" default
```

**Expected Output:** JWT access token (starts with `eyJ...`)

**Decoded Token:**
```json
{
  "aud": ["data-service"],
  "iss": "https://provider-verifier...",
  "sub": "did:web:fancy-marketplace.biz",
  "verifiableCredential": {...}
}
```

**Status:** ✅ Works with UserCredential + default scope

---

### 4.4 Data Access

**Command:**
```bash
curl -X GET 'http://mp-data-service.192.168.120.128.nip.io:8080/ngsi-ld/v1/entities/urn:ngsi-ld:EnergyReport:fms-1' \
    -H "Authorization: Bearer ${DATA_SERVICE_ACCESS_TOKEN}"
```

**Expected Output:**
```json
{
  "id": "urn:ngsi-ld:EnergyReport:fms-1",
  "type": "EnergyReport",
  "consumption": {"type": "Property", "value": "94"},
  "name": {"type": "Property", "value": "Standard Server"}
}
```

**Status:** ✅ Works

---

### 4.5 OperatorCredential + operator scope

**Command:**
```bash
./doc/scripts/get_access_token_oid4vp.sh \
    http://mp-data-service.192.168.120.128.nip.io:8080 "$OPERATOR_CREDENTIAL" operator
```

**Expected Output:** JWT access token

**Actual Output:** `null` (or empty)

**Status:** ⚠️ Issue - credentialSubject format mismatch

---

## 5. Key Environment Variables

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `HOLDER_DID` | `did:key:zDnae...` | Consumer's DID (generated) |
| `PROVIDER_DID` | `did:web:mp-operations.org` | Provider's DID |
| `CONSUMER_DID` | `did:web:fancy-marketplace.biz` | Consumer's DID |
| `ACCESS_TOKEN` | `eyJ...` | Keycloak access token |
| `CREDENTIAL_ACCESS_TOKEN` | `eyJ...` | OID4VC credential token |
| `VERIFIABLE_CREDENTIAL` | `eyJ...` | Issued credential JWT |
| `TOKEN_ENDPOINT` | `https://provider-verifier.../token` | VP token exchange endpoint |
| `DATA_SERVICE_ACCESS_TOKEN` | `eyJ...` | Final access token |

---

## 6. Available Endpoints

| Endpoint | URL | Purpose |
|----------|-----|---------|
| TIR | `http://tir.192.168.120.128.nip.io:8080` | Trusted Issuers Registry |
| TIL | `http://til.192.168.120.128.nip.io:8080` | Trusted Issuers List API |
| Keycloak Consumer | `https://keycloak-consumer.192.168.120.128.nip.io` | Credential issuance |
| Data Service | `http://mp-data-service.192.168.120.128.nip.io:8080` | Protected data API |
| Verifier | `https://provider-verifier.192.168.120.128.nip.io:8443` | OID4VP authentication |
| Scorpio | `http://scorpio-provider.192.168.120.128.nip.io:8080` | Context Broker |
| PAP | `http://pap-provider.192.168.120.128.nip.io:8080` | Policy Administration |
| TM Forum API | `http://tm-forum-api.192.168.120.128.nip.io:8080` | Product catalog |
| CCS | `http://provider-ccs.192.168.120.128.nip.io:8080` | Credential config |

---

## 7. Keycloak Users

| Username | Password | Credential Type | Roles |
|----------|----------|----------------|-------|
| employee | test | UserCredential | REPRESENTATIVE, READER, customer |
| representative | test | UserCredential | REPRESENTATIVE |
| operator | test | OperatorCredential | OPERATOR |

---

## 8. Common Issues and Fixes

### Issue 1: br_netfilter not enabled

**Symptom:** Networking issues inside K3s cluster

**Fix:**
```bash
sudo modprobe br_netfilter
```

### Issue 2: Maven build fails

**Symptom:** Certificate generation errors

**Fix:**
```bash
rm -rf helpers/certs/out
mvn clean install -Plocal -DskipTests -Ddocker.skip
```

### Issue 3: OperatorCredential returns null

**Symptom:** `./doc/scripts/get_access_token_oid4vp.sh ... operator` returns null

**Fix:** Keycloak credential template needs adjustment (credentialSubject should be array)

### Issue 4: Traefik 502/504 errors

**Symptom:** Services not accessible via ingress

**Fix:** Check service ports match ingress configuration

---

## 9. Helper Scripts

### get_credential.sh
```bash
./doc/scripts/get_credential.sh <keycloak-url> <credential-type> <username>
```

**Examples:**
```bash
./doc/scripts/get_credential.sh https://keycloak-consumer.192.168.120.128.nip.io user-credential employee
./doc/scripts/get_credential.sh https://keycloak-consumer.192.168.120.128.nip.io operator-credential operator
```

### get_access_token_oid4vp.sh
```bash
./doc/scripts/get_access_token_oid4vp.sh <data-service-url> <credential> <scope>
```

**Examples:**
```bash
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$CRED" default
./doc/scripts/get_access_token_oid4vp.sh http://mp-data-service.192.168.120.128.nip.io:8080 "$OPERATOR_CRED" operator
```

---

## 10. DID Methods Comparison

| Method | LOCAL.MD | CENTRAL_MARKETPLACE |
|--------|----------|---------------------|
| DID | `did:key` | `did:web` |
| Resolution | Self-contained | Requires DID document hosting |
| Key Generation | did-helper Docker container | mvn deploy |
| Trust Framework | Basic | Full eIDAS/DSS |

---

## 11. Execution Checklist

- [ ] Run `mvn clean deploy -Plocal`
- [ ] Verify K3s cluster: `kubectl get pods -A`
- [ ] Check TIR: `curl http://tir.192.168.120.128.nip.io:8080/v4/issuers`
- [ ] Generate DID: `docker run -v $(pwd)/cert:/cert quay.io/wi_stefan/did-helper:0.1.1`
- [ ] Get credentials via script or manual flow
- [ ] Create ODRL policies at PAP
- [ ] Create test entity in Scorpio
- [ ] Test OID4VP authentication flow
- [ ] Access protected data with token
- [ ] Complete marketplace demo (if desired)

---

## 12. Next Steps

1. **If OperatorCredential fails:** Fix Keycloak credential template
2. **For full demo:** Execute marketplace section with organization registration and ordering
3. **For production:** Configure proper DNS for did:web instead of nip.io
4. **For eIDAS:** Follow eIDAS section in LOCAL.MD with proper certificates

# FIWARE Deployment Gap Analysis & Improvement Report

**Date:** 2026-03-31  
**Script Version:** v5 → v6 (this report)  
**Knowledge Base:** 1,538 docs indexed from FIWARE/data-space-connector, FIWARE/helm-charts, FIWARE/tutorials.NGSI-LD

---

## 1. What Was Fixed in the Script

### Bug: VCVerifier returns 404 at `/services/data-service/token` (UC-F5 blocker)
**Root cause:** The Credentials Config Service (CCS) is deployed empty. It has no scope mappings at all. The VCVerifier reads CCS to find which credentials to accept per service and scope. Without any entry for `data-service`, the verifier has no route to register and returns Go-lang 404.

**Fix applied (Phase 6.7):** Post-deploy `curl -X PUT http://provider-ccs.../service/data-service` with full scope config: `default` → UserCredential, `operator` → OperatorCredential, `legal` → LegalPersonCredential, `openid` → MembershipCredential.

### Bug: OperatorCredential scope returns null (Central Marketplace blocker)
**Root cause:** Same as above. The `operator` scope had no credential mapping in CCS.

**Fix applied (Phase 6.7):** Same CCS PUT — the `operator` scope now maps to OperatorCredential with proper TIR and TIL references.

### Gap: No baseline ODRL policies created post-deploy
**Root cause:** The script deployed everything but created zero policies. Every TMForum interaction (read offerings, register org, create orders) requires a PAP policy.

**Fix applied (Phase 6.8):** Auto-creates 6 policies on first deploy:
1. EnergyReport read (any credential)
2. productOffering read (any credential) 
3. organization create (REPRESENTATIVE role)
4. productOrder create (REPRESENTATIVE role)
5. K8SCluster read (OperatorCredential with OPERATOR role)
6. Contract Management order notifications (MarketplaceCredential)

### Gap: DSP/EDC profile never activated
**Root cause:** Script used `mvn clean install -Plocal`. DSP profile (`-Plocal,dsp`) deploys FDSC-EDC, Vault, and IdentityHub (Tractus-X) via `dsp-provider.yaml` + `dsp-consumer.yaml`. Without this, all of `DSP_INTEGRATION.md` is inaccessible.

**Fix applied:** Added `--dsp` flag. When used, Maven profile becomes `local,dsp` and Phase 6.9 auto-registers participant identities in IdentityHub.

### Gap: Gaia-X profile never activated
**Root cause:** Script had no path to `mvn clean install -Plocal,gaia-x`. This profile deploys GX-Registry, DSS validation service, Squid HTTPS proxy, and Traefik TLS.

**Fix applied:** Added `--gaia-x` flag.

### Gap: No DSP endpoint smoke tests
**Fix applied:** Smoke tests now cover TMForum, CCS, VCVerifier openid-config, mp-data-service openid-config, and (when DSP enabled) DSP catalog + IdentityHub did.json.

---

## 2. Document Coverage Matrix

| Document | Status Before | Status After Script Fix | Remaining Manual Steps |
|----------|--------------|------------------------|----------------------|
| **LOCAL.MD** | ⚠️ UC-F5 broken, no policies | ✅ Fully automated | Issue credentials, create offerings, run buy flow |
| **CENTRAL_MARKETPLACE.md** | ⚠️ OperatorCredential null | ✅ CCS + policies fixed | prepare-central-market-policies.sh, provider registration, offering creation |
| **CONTRACT_NEGOTIATION.md** | N/A (deprecated) | N/A — Rainbow is deprecated, EDC extension replaces it | None needed |
| **DSP_INTEGRATION.md** | ❌ Profile never activated | ✅ `--dsp` flag activates | MembershipCredential issuance + IdentityHub insert, Scorpio data, TMForum DSP offering |
| **GAIA_X.MD** | ❌ Profile never activated | ✅ `--gaia-x` flag activates | Pre-generate eIDAS certs via helpers/certs, browser proxy config |
| **MARKETPLACE_INTEGRATION.md** | ⚠️ BAE deployed, no wallet | ⚠️ No change possible | EUDI wallet APK install, phone WiFi proxy, FoxyProxy browser extension |
| **RAINBOW_INTEGRATION.md** | N/A (deprecated) | N/A — superseded by DSP_INTEGRATION.md + FDSC-EDC | None needed |
| **ONGOING_WORK.md** | Informational | Informational | Monitor FIWARE repo for Gaia-X credential chain (24.07) updates |

---

## 3. What YOU Still Need to Do (Manual Steps Per Document)

### Always required (every deployment)

```bash
# 1. Open a NEW shell after deployment (so .bashrc loads INTERNAL_IP)
source ~/.bashrc
echo $INTERNAL_IP   # Verify this prints your VM IP

# 2. Issue the three credentials you need for all demo flows
export USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential employee)

export REP_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential representative)

export OPERATOR_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io operator-credential operator)
```

### LOCAL.MD — Buy access + K8S cluster flow

```bash
# After credentials above are set:
export PROVIDER_DID="did:web:mp-operations.org"
export CONSUMER_DID="did:web:fancy-marketplace.biz"

# Create K8S product specs + offerings (LOCAL.MD steps 2-3)
# See LOCAL.MD §Offer creation — run the curl commands for PRODUCT_SPEC_SMALL_ID, 
# PRODUCT_SPEC_FULL_ID, PRODUCT_OFFERING_SMALL_ID, PRODUCT_OFFERING_FULL_ID

# Then run the buy-access flow (LOCAL.MD §Buy access and create cluster steps 3-10)
```

### CENTRAL_MARKETPLACE.md — Full central marketplace flow

```bash
# Step 1: Apply central market TMForum policies
./doc/scripts/prepare-central-market-policies.sh

# Step 2: Get provider credential
export PROVIDER_USER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-provider.${INTERNAL_IP}.nip.io user-credential employee)

# Step 3: Allow Contract Management at provider PAP
curl -X 'POST' http://pap-provider.${INTERNAL_IP}.nip.io:8080/policy \
    -H 'Content-Type: application/json' \
    -d "$(cat ./it/src/test/resources/policies/allowContractManagement.json)"

# Steps 4+: Follow CENTRAL_MARKETPLACE.md §Prepare the provider and §Create the Offering
```

### DSP_INTEGRATION.md (requires `--dsp` flag on deployment)

```bash
# After ./fiware_deployment.sh <IP> --dsp completes:

# 1. Issue and insert MembershipCredentials into IdentityHub for both participants
export CONSUMER_CREDENTIAL=$(./doc/scripts/get_credential.sh \
    https://keycloak-consumer.${INTERNAL_IP}.nip.io membership-credential employee)
export CONSUMER_CREDENTIAL_CONTENT=$(./doc/scripts/get-payload-from-jwt.sh \
    "${CONSUMER_CREDENTIAL}" | jq -r '.vc')

curl -X POST \
  "http://identityhub-management-fancy-marketplace.${INTERNAL_IP}.nip.io:8080/api/identity/v1alpha/participants/ZGlkOndlYjpmYW5jeS1tYXJrZXRwbGFjZS5iaXo/credentials" \
  --header 'x-api-key: c3VwZXItdXNlcg==.random' \
  --header 'Content-Type: application/json' \
  --data-raw "{
    \"id\": \"membership-credential\",
    \"participantContextId\": \"did:web:fancy-marketplace.biz\",
    \"verifiableCredentialContainer\": {
      \"rawVc\": \"${CONSUMER_CREDENTIAL}\",
      \"format\": \"VC1_0_JWT\",
      \"credential\": ${CONSUMER_CREDENTIAL_CONTENT}
    }
  }"
# Repeat for provider — see DSP_INTEGRATION.md §Issue membership-credentials §Provider

# 2. Add test data to Scorpio
curl -X POST http://scorpio-provider.${INTERNAL_IP}.nip.io:8080/ngsi-ld/v1/entities \
  -H 'Content-Type: application/json' \
  -d '{"id":"urn:ngsi-ld:UptimeReport:fms-1","type":"UptimeReport",
       "name":{"type":"Property","value":"Standard Server"},
       "uptime":{"type":"Property","value":"99.9"}}'

# 3. Create TMForum product spec + offering with DSP endpoint characteristics
#    See DSP_INTEGRATION.md §Prepare the offering (the long productSpecification curl)

# 4. Run DCP catalog read + negotiation + transfer
#    See DSP_INTEGRATION.md §Order through DSP §DCP steps 1-8
```

### GAIA_X.MD (requires `--gaia-x` flag on deployment)

```bash
# BEFORE running the deployment script with --gaia-x:
cd /fiware/data-space-connector/helpers/certs

# Create config file
cat > output/config << 'EOF'
COUNTRY="DE"
LOCALITY="Berlin"
STATE="Berlin"
ORGANISATION_IDENTIFIER="VATDE-1234567"
ORGANISATION="Test org"
COMMON_NAME="Test"
EMAIL="test@test.org"
CRL_URI=http://localhost:3000/crl.pem
EOF

mkdir -p output
docker run -v $(pwd)/output:/out -v $(pwd)/output/config:/config/config quay.io/fiware/eidas:1.3.2

# THEN run: ./fiware_deployment.sh <IP> --gaia-x

# After deployment, test did:web resolution:
curl -k -x localhost:8888 https://fancy-marketplace.biz/.well-known/did.json | jq .

# Configure browser: FoxyProxy → HTTP proxy → 127.0.0.1:8888
# Then open: https://marketplace.${INTERNAL_IP}.nip.io
```

### MARKETPLACE_INTEGRATION.md (BAE Marketplace + EUDI Wallet)

```
ON YOUR PHONE/EMULATOR:
1. Download EUDI wallet APK (link in MARKETPLACE_INTEGRATION.md §The Wallet)
2. Install: adb install app-dev-debug.apk  (or sideload on phone)
3. Set WiFi proxy:
   - Hostname: <YOUR_VM_IP>
   - Port: 8888

IN CHROME ON YOUR LAPTOP:
1. Install FoxyProxy extension
2. Options → Proxies → Add: Type=HTTP, Hostname=127.0.0.1, Port=8888
3. Enable FoxyProxy
4. Open https://marketplace.<IP>.nip.io (accept cert warning)
5. Login with wallet credential → follow MARKETPLACE_INTEGRATION.md §Usage
```

---

## 4. Deployment Commands Summary

```bash
# Standard deployment (LOCAL.MD + CENTRAL_MARKETPLACE.md)
./fiware_deployment.sh <IP>

# DSP/EDC deployment (adds DSP_INTEGRATION.md support)
./fiware_deployment.sh <IP> --dsp

# Gaia-X deployment (adds GAIA_X.MD support — generate eIDAS certs first!)
./fiware_deployment.sh <IP> --gaia-x

# Full deployment (all capabilities)
./fiware_deployment.sh <IP> --dsp --gaia-x

# Skip auto-setup (manual control)
./fiware_deployment.sh <IP> --no-ccs --no-policies
```

---

## 5. Known Remaining Issues

| Issue | Impact | Fix |
|-------|--------|-----|
| TMForum POST offerings returns 400 | Can't create offerings via API without required reference fields | Always create category + catalog first, then spec, then offering. Follow LOCAL.MD order exactly |
| BAE Marketplace requires real wallet | Can't test full GUI flow without phone/emulator | Use EUDI APK sideload — instructions in MARKETPLACE_INTEGRATION.md |
| Gaia-X `did:web` needs HTTPS + valid cert chain | GX-Registry rejects self-signed certs without proper chain | Use helpers/certs scripts to generate proper chain |
| DSP_INTEGRATION.md MembershipCredential insert | Must be done after IdentityHub is up; Phase 6.9 registers identity but not credentials | Run the manual credential insert steps listed above |
| Keycloak 26.x realm config format changed (v8.x) | Client scope format changed — some credential types may not issue | See docs/VERSION_COMPATIBILITY.md §KEYCLOAK_26 for updated realm YAML |

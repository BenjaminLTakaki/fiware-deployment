# FIWARE Marketplace Login Fix Guide

**Environment:** Fontys NetLab K3s Cluster, IP `192.168.120.128`  
**Problem:** Clicking the login button on `https://marketplace.192.168.120.128.nip.io/dashboard` redirects to an unresolvable external domain, preventing the OID4VP login flow from completing.  
**Root causes:** Five separate issues, fixed in order below.

---

## Background

The FIWARE Data Space Connector uses hardcoded external domain names (`mp-operations.org`, `fancy-marketplace.biz`) throughout its Helm chart defaults. In a NetLab deployment these domains do not resolve in public DNS. Additionally, the Maven build bakes TLS certificates with `127.0.0.1.nip.io` SANs rather than the actual VM IP, causing certificate validation failures for intra-cluster HTTPS calls.

The login flow works as follows:

1. Browser hits `marketplace.192.168.120.128.nip.io/dashboard`
2. Clicking login causes the logic proxy to generate a `loginQR` redirect URL pointing to the verifier
3. The verifier fetches a signed request JWT from the marketplace's `/auth/vc/request.jwt` endpoint
4. The verifier validates the JWT and issues a QR code or deep link for wallet authentication

Each step had a blocker. The fixes below address them in the order they surfaced.

---

## Fix 1: Logic Proxy -- Verifier Host Hardcoded in StatefulSet Env

**Symptom:** Login button redirects to `https://verifier.mp-operations.org/api/v2/loginQR?...` which fails with `DNS_PROBE_FINISHED_NXDOMAIN`.

**Cause:** The `provider-biz-ecosystem-logic-proxy` StatefulSet has `BAE_LP_SIOP_VERIFIER_HOST=https://verifier.mp-operations.org` hardcoded as an environment variable in the pod spec, not in a ConfigMap. The deployment script's `sed` pass only replaced `127.0.0.1.nip.io` references, leaving `mp-operations.org` untouched.

**Fix:** Add a nip.io ingress for the provider verifier, patch the verifier ConfigMap `server.host`, and patch the StatefulSet env var.

### Step 1a: Add a local ingress for the provider verifier

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: verifier-local
  namespace: provider
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
  - host: verifier-provider.192.168.120.128.nip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: verifier
            port:
              number: 3000
  tls:
  - hosts:
    - verifier-provider.192.168.120.128.nip.io
    secretName: tls-secret
EOF
```

Note: use `verifier-provider` not `verifier` as the subdomain, to avoid hostname collision with the consumer verifier ingress which uses `verifier.192.168.120.128.nip.io`.

### Step 1b: Patch the provider verifier ConfigMap

```bash
kubectl patch configmap verifier -n provider --type merge -p '
{
  "data": {
    "server.yaml": "server:\n  host: https://verifier-provider.192.168.120.128.nip.io\n  port: 3000\n  staticDir: views/static\n  templateDir: views/\n\nm2m:\n  authEnabled: false\n  clientId: null\n  credentialPath: null\n  keyPath: null\n  keyType: RSAPS256\n  signatureType: null\n  verificationMethod: null\n  \nlogging:\n  jsonLogging: true\n  level: DEBUG\n  logRequests: true\n  pathsToSkip:\n  - /metrics\n  - /health\n\nverifier:\n  clientIdentification:\n    certificatePath: /certificate/client-chain-bundle.cert.pem\n    id: x509_san_dns:verifier.mp-operations.org\n    keyPath: /signing-key/client.key.pem\n    requestKeyAlgorithm: ES256\n  did: did:web:mp-operations.org\n  sessionExpiry: 30\n  supportedModes:\n  - byValue\n  - byReference\n  tirAddress: http://tir.192.168.120.128.nip.io/\n  validationMode: none\n\nconfigRepo:\n  configEndpoint: http://credentials-config-service:8080\n\nelsi:"
  }
}'
```

Note: `verifier.did` and `verifier.clientIdentification.id` stay as `mp-operations.org` -- these are cryptographic identity values tied to the deployed keys and must not change. Only `server.host` changes.

### Step 1c: Restart the provider verifier

```bash
kubectl rollout restart deployment verifier -n provider
kubectl rollout status deployment verifier -n provider
```

### Step 1d: Patch the StatefulSet with the full correct env

The StatefulSet has about 60 environment variables. Replace the entire env block to change `BAE_LP_SIOP_VERIFIER_HOST` while preserving all other vars including MongoDB credentials (which were missing in an earlier partial patch and caused CrashLoopBackOff):

```bash
kubectl patch statefulset provider-biz-ecosystem-logic-proxy -n provider --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "NODE_ENV", "value": "production"},
    {"name": "COLLECT", "value": "True"},
    {"name": "BAE_LP_PORT", "value": "8004"},
    {"name": "BAE_LP_HOST", "value": "provider-biz-ecosystem-logic-proxy.provider.svc.cluster.local"},
    {"name": "BAE_LP_MONGO_SERVER", "value": "mongodb-svc"},
    {"name": "BAE_LP_MONGO_PORT", "value": "27017"},
    {"name": "BAE_LP_MONGO_DB", "value": "belp_db"},
    {"name": "BAE_LP_MONGO_USER", "value": "belp"},
    {"name": "BAE_LP_MONGO_PASS", "valueFrom": {"secretKeyRef": {"key": "password", "name": "mongodb-belp-password"}}},
    {"name": "BAE_LP_OAUTH2_ADMIN_ROLE", "value": "admin"},
    {"name": "BAE_LP_OAUTH2_SELLER_ROLE", "value": "seller"},
    {"name": "BAE_LP_OAUTH2_CUSTOMER_ROLE", "value": "customer"},
    {"name": "BAE_LP_OAUTH2_ORG_ADMIN_ROLE", "value": "orgAdmin"},
    {"name": "BAE_LP_OAUTH2_PROVIDER", "value": "vc"},
    {"name": "BAE_LP_OAUTH2_IS_LEGACY", "value": "false"},
    {"name": "BAE_LP_REVENUE_MODEL", "value": "30"},
    {"name": "BAE_LP_ENDPOINT_CATALOG_HOST", "value": "provider-tm-forum-api-product-catalog"},
    {"name": "BAE_LP_ENDPOINT_CATALOG_PATH", "value": "/tmf-api/productCatalogManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_CATALOG_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_INVENTORY_HOST", "value": "provider-tm-forum-api-product-inventory"},
    {"name": "BAE_LP_ENDPOINT_INVENTORY_PATH", "value": "/tmf-api/productInventory/v4"},
    {"name": "BAE_LP_ENDPOINT_INVENTORY_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_SERVICE_INVENTORY_HOST", "value": "provider-biz-ecosystem-apis.provider.svc.cluster.local"},
    {"name": "BAE_LP_ENDPOINT_SERVICE_INVENTORY_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_INVENTORY_HOST", "value": "provider-tm-forum-api-resource-inventory"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_INVENTORY_PATH", "value": "/tmf-api/resourceInventoryManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_INVENTORY_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_ORDERING_HOST", "value": "provider-tm-forum-api-product-ordering-management"},
    {"name": "BAE_LP_ENDPOINT_ORDERING_PATH", "value": "/tmf-api/productOrderingManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_ORDERING_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_BILLING_HOST", "value": "provider-tm-forum-api-account"},
    {"name": "BAE_LP_ENDPOINT_BILLING_PATH", "value": "/tmf-api/accountManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_BILLING_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_HOST", "value": "provider-tm-forum-api-resource-catalog"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_PATH", "value": "/tmf-api/resourceCatalog/v4"},
    {"name": "BAE_LP_ENDPOINT_RESOURCE_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_SERVICE_HOST", "value": "provider-tm-forum-api-service-catalog"},
    {"name": "BAE_LP_ENDPOINT_SERVICE_PATH", "value": "/tmf-api/serviceCatalogManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_SERVICE_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_RSS_HOST", "value": "provider-biz-ecosystem-rss.provider.svc.cluster.local"},
    {"name": "BAE_LP_ENDPOINT_RSS_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_USAGE_HOST", "value": "provider-tm-forum-api-usage-management"},
    {"name": "BAE_LP_ENDPOINT_USAGE_PATH", "value": "/tmf-api/usageManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_USAGE_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_PARTY_HOST", "value": "provider-tm-forum-api-party-catalog"},
    {"name": "BAE_LP_ENDPOINT_PARTY_PATH", "value": "/tmf-api/party/v4"},
    {"name": "BAE_LP_ENDPOINT_PARTY_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_CUSTOMER_HOST", "value": "provider-tm-forum-api-customer-management"},
    {"name": "BAE_LP_ENDPOINT_CUSTOMER_PATH", "value": "/tmf-api/customerManagement/v4"},
    {"name": "BAE_LP_ENDPOINT_CUSTOMER_PORT", "value": "8080"},
    {"name": "BAE_LP_ENDPOINT_CHARGING_HOST", "value": "provider-biz-ecosystem-charging-backend.provider.svc.cluster.local"},
    {"name": "BAE_LP_ENDPOINT_CHARGING_PORT", "value": "8006"},
    {"name": "BAE_LP_INDEX_ENGINE", "value": "elasticsearch"},
    {"name": "BAE_LP_INDEX_API_VERSION", "value": "7"},
    {"name": "BAE_LP_INDEX_URL", "value": "elasticsearch:9200"},
    {"name": "BAE_SERVICE_HOST", "value": "https://marketplace.192.168.120.128.nip.io"},
    {"name": "BAE_LP_OIDC_ENABLED", "value": "false"},
    {"name": "BAE_LP_EXT_LOGIN", "value": "true"},
    {"name": "BAE_LP_SHOW_LOCAL_LOGIN", "value": "false"},
    {"name": "BAE_LP_ALLOW_LOCAL_EORI", "value": "false"},
    {"name": "BAE_LP_EDIT_PARTY", "value": "true"},
    {"name": "BAE_LP_PROPAGATE_TOKEN", "value": "true"},
    {"name": "BAE_LP_SIOP_ENABLED", "value": "true"},
    {"name": "BAE_LP_SIOP_VERIFIER_HOST", "value": "https://verifier-provider.192.168.120.128.nip.io"},
    {"name": "BAE_LP_SIOP_VERIFIER_QRCODE_PATH", "value": "/api/v2/loginQR"},
    {"name": "BAE_LP_SIOP_VERIFIER_TOKEN_PATH", "value": "/token"},
    {"name": "BAE_LP_SIOP_VERIFIER_JWKS_PATH", "value": "/.well-known/jwks"},
    {"name": "BAE_LP_SIOP_CALLBACK_PATH", "value": "https://marketplace.192.168.120.128.nip.io/auth/vc/callback"},
    {"name": "BAE_LP_SIOP_ALLOWED_ROLES", "value": "seller,customer,admin,REPRESENTATIVE,READER,OPERATOR"},
    {"name": "BAE_LP_SIOP_IS_REDIRECTION", "value": "true"},
    {"name": "BAE_LP_PURCHASE_ENABLED", "value": "true"},
    {"name": "NODE_TLS_REJECT_UNAUTHORIZED", "value": "0"},
    {"name": "HTTPS_PROXY", "value": "http://squid-proxy.infra.svc.cluster.local:8888"},
    {"name": "BAE_LP_SIOP_CLIENT_ID", "value": "did:web:mp-operations.org"},
    {"name": "BAE_LP_SIOP_PRIVATE_KEY", "valueFrom": {"secretKeyRef": {"key": "key", "name": "signing-key-env"}}}
  ]}
]'
```

Then delete the pod to force a restart (StatefulSets do not restart on spec change alone):

```bash
kubectl delete pod provider-biz-ecosystem-logic-proxy-0 -n provider
kubectl get pod -n provider -w | grep logic-proxy
# Wait for 1/1 Running
```

**Expected result:** Login button now redirects to `https://verifier-provider.192.168.120.128.nip.io/api/v2/loginQR?...` which resolves via public nip.io DNS.

---

## Fix 2: Verifier NO_PROXY Blocking Request JWT Fetch

**Symptom:** Verifier URL resolves but returns `{"summary":"unresolvable_request_object","details":"Was not able to get the request object from the client."}`.

**Cause:** The verifier pod has `NO_PROXY=credentials-config-service,w3.org,trusted-issuers-list,.nip.io`. The `.nip.io` entry causes the Go HTTP client to bypass the squid proxy for nip.io addresses and attempt direct connections, which fail because `192.168.120.128` is not routable from inside the cluster without the proxy.

**Fix:** Remove `.nip.io` from `NO_PROXY` on both the verifier deployment and the logic proxy StatefulSet.

```bash
# Fix verifier deployment NO_PROXY
kubectl patch deployment verifier -n provider --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env", "value":
    '"$(kubectl get deployment verifier -n provider -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -c "
import json,sys
envs = json.load(sys.stdin)
envs = [e for e in envs if e.get('name') != 'NO_PROXY']
envs.append({'name': 'NO_PROXY', 'value': 'credentials-config-service,w3.org,trusted-issuers-list'})
print(json.dumps(envs))
")"'
}]'

# Fix logic proxy StatefulSet NO_PROXY
kubectl set env statefulset/provider-biz-ecosystem-logic-proxy \
  NO_PROXY="credentials-config-service,w3.org,trusted-issuers-list" \
  -n provider

# Restart verifier
kubectl rollout restart deployment verifier -n provider
kubectl rollout status deployment verifier -n provider

# Restart logic proxy
kubectl delete pod provider-biz-ecosystem-logic-proxy-0 -n provider
kubectl get pod -n provider -w | grep logic-proxy
```

**Expected result:** Verifier can now reach `marketplace.192.168.120.128.nip.io` via squid proxy. However a new TLS error surfaces (see Fix 3).

---

## Fix 3: TLS Certificate SAN Mismatch

**Symptom:** Verifier logs show:
```
tls: failed to verify certificate: x509: certificate is valid for
358ac33bc2d4ccccb81666091e3baeec.b5b5006b65d49add8bdb85a6301466da.traefik.default,
not marketplace.192.168.120.128.nip.io
```

**Cause:** The Maven build generates TLS certificates during the build phase, before the IP replacement `sed` pass runs. As a result all SANs in `tls-secret` and `local-wildcard` contain `*.127.0.0.1.nip.io` instead of `*.192.168.120.128.nip.io`. Traefik falls back to its internal self-signed certificate for any hostname that doesn't match a loaded secret's SAN, and the verifier's Go HTTP client rejects that certificate.

**Fix:** Generate a new self-signed certificate with the correct IP in the SAN, create a new secret from it, assign it to the marketplace ingress, mount it into the verifier pod, and set `SSL_CERT_FILE` so the Go runtime trusts it.

### Step 3a: Generate the certificate

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /tmp/nip-key.pem \
  -out /tmp/nip-cert.pem \
  -days 365 -nodes \
  -subj "/CN=*.192.168.120.128.nip.io" \
  -addext "subjectAltName=DNS:*.192.168.120.128.nip.io,DNS:marketplace.192.168.120.128.nip.io,DNS:verifier-provider.192.168.120.128.nip.io,DNS:verifier.192.168.120.128.nip.io"
```

### Step 3b: Create the secret in all relevant namespaces

```bash
for ns in provider consumer infra; do
  kubectl create secret tls nip-tls \
    --cert=/tmp/nip-cert.pem \
    --key=/tmp/nip-key.pem \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
```

### Step 3c: Assign the secret to the marketplace ingress

```bash
kubectl patch ingress provider-biz-ecosystem-logic-proxy -n provider --type='json' -p='[
  {"op": "replace", "path": "/spec/tls/0/secretName", "value": "nip-tls"}
]'
```

### Step 3d: Create a ConfigMap with the CA cert for the verifier

```bash
kubectl create configmap nip-ca -n provider \
  --from-file=nip-ca.crt=/tmp/nip-cert.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 3e: Mount the CA cert into the verifier and set SSL_CERT_FILE

```bash
kubectl patch deployment verifier -n provider --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "nip-ca",
    "configMap": {"name": "nip-ca"}
  }},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
    "name": "nip-ca",
    "mountPath": "/etc/ssl/nip-ca.crt",
    "subPath": "nip-ca.crt"
  }},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {
    "name": "SSL_CERT_FILE",
    "value": "/etc/ssl/nip-ca.crt"
  }}
]'
```

### Step 3f: Restart the verifier

```bash
kubectl rollout restart deployment verifier -n provider
kubectl rollout status deployment verifier -n provider
```

**Expected result:** Login flow completes past the `unresolvable_request_object` error. The verifier can now fetch the request JWT and the browser reaches the QR/deep link page.

---

## Summary of All Changes Made

| Resource | Namespace | Change |
|---|---|---|
| `Ingress/verifier-local` | `provider` | Created -- routes `verifier-provider.192.168.120.128.nip.io` to verifier pod |
| `Ingress/verifier-local` | `consumer` | Created -- routes `verifier.192.168.120.128.nip.io` to consumer verifier pod |
| `ConfigMap/verifier` | `provider` | `server.host` changed from `https://verifier.mp-operations.org` to `https://verifier-provider.192.168.120.128.nip.io` |
| `ConfigMap/verifier` | `consumer` | `server.host` changed from `https://verifier.fancy-marketplace.biz` to `https://verifier.192.168.120.128.nip.io` |
| `StatefulSet/provider-biz-ecosystem-logic-proxy` | `provider` | `BAE_LP_SIOP_VERIFIER_HOST` changed to `https://verifier-provider.192.168.120.128.nip.io`; `NO_PROXY` updated to remove `.nip.io` |
| `Deployment/verifier` | `provider` | `NO_PROXY` updated to remove `.nip.io`; `SSL_CERT_FILE` added; `nip-ca` volume mounted |
| `Ingress/provider-biz-ecosystem-logic-proxy` | `provider` | TLS secret changed from `local-wildcard` to `nip-tls` |
| `Secret/nip-tls` | `provider`, `consumer`, `infra` | Created -- self-signed cert with correct `*.192.168.120.128.nip.io` SAN |
| `ConfigMap/nip-ca` | `provider` | Created -- contains the nip-tls CA cert for verifier trust |

---

## Why the Root Causes Exist

The FIWARE Data Space Connector Helm charts use fictional domain names (`mp-operations.org`, `fancy-marketplace.biz`) as defaults throughout their templates. These are intended for demo environments with local `/etc/hosts` overrides or split-horizon DNS. The deployment script patches YAML files with `sed` but runs after Maven, which has already baked the original IP (`127.0.0.1`) into TLS certificates. In a fresh NetLab deployment with a different IP, both the domain names and the cert SANs are wrong and must be patched manually as described above.

---

## Notes for Future Deployments

To avoid these issues on a fresh deployment, add the following to `fiware_deployment.sh` after the Maven build step and before pod deployment:

1. Run `openssl` to regenerate a wildcard cert for `*.${INTERNAL_IP}.nip.io` and replace `tls-secret` in all namespaces before applying the K8s manifests.
2. Add `BAE_LP_SIOP_VERIFIER_HOST` patching to the post-deploy section alongside the existing APISIX and Keycloak patches.
3. Add `.nip.io` removal from `NO_PROXY` for the verifier deployment as a post-deploy patch.
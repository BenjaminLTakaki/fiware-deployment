# FIWARE Marketplace Registration Fix Guide

**Environment:** Fontys NetLab K3s Cluster, IP `192.168.120.128`
**Problem:** Clicking the "Register" button on `https://marketplace.192.168.120.128.nip.io/dashboard` redirects to the external DOME onboarding portal (`https://dome-marketplace.github.io/onboarding/`) instead of a local registration flow, making it impossible to test user registration in a local deployment.
**Prerequisite:** The login QR code fix from `Marketplace_Logging_Fix.md` must be applied first.

---

## Background

The BAE Logic Proxy (`fiware/biz-ecosystem-logic-proxy:10.5.0-PRE-1`) uses a DOME-specific configuration variable `BAE_LP_DOME_REGISTER` to control where the "Register" button points. When this variable is not set, the code in `etc/config.js` defaults to the external DOME onboarding portal:

```javascript
config.domeRegister = process.env.BAE_LP_DOME_REGISTER || "https://dome-marketplace.github.io/onboarding/";
```

In a local NetLab deployment, this external URL is unreachable (or undesirable for testing). The fix redirects registration to the Provider Keycloak instance running inside the cluster, which has a `test-realm` that can be configured for self-registration.

---

## Architecture Notes

All browser traffic in this deployment is routed through the **Squid forward proxy** (port `8888` on the VM). Squid forwards:
- HTTP requests → `traefik-loadbalancer-in.infra.svc.cluster.local:80`
- HTTPS requests (via CONNECT tunnelling) → `traefik-loadbalancer-in.infra.svc.cluster.local:443`

The Keycloak ingress has `traefik.ingress.kubernetes.io/router.tls: "true"`, meaning it is **HTTPS only**. The registration URL must use `https://`, not `http://`, or Traefik will return 404.

Key endpoints (replace `192.168.120.128` with your VM IP if different):

| Service | URL |
|---|---|
| Marketplace | `https://marketplace.192.168.120.128.nip.io` |
| Provider Keycloak | `https://keycloak-provider.192.168.120.128.nip.io` |
| Keycloak realm | `test-realm` |
| Squid proxy | `192.168.120.128:8888` |

---

## System Prerequisites

Before applying this fix, ensure the system is stable:

```bash
# Check K3s is running and kubectl works
sudo k3s kubectl get nodes

# Check disk space (88%+ can cause K3s API crashes)
df -h /

# Check inotify limits (exhaustion causes TLS handshake timeouts)
cat /proc/sys/fs/inotify/max_user_watches
```

### Fix: Disk Space (if over 85%)

```bash
# Clean journal logs
sudo journalctl --vacuum-time=2d

# If LVM volume is smaller than the physical disk, expand it
sudo vgdisplay ubuntu-vg | grep -E "VG Size|Free PE"
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

### Fix: Inotify Limits (if kubectl times out with TLS errors)

```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
sudo sysctl fs.inotify.max_queued_events=16384

echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\nfs.inotify.max_queued_events=16384" \
  | sudo tee /etc/sysctl.d/99-inotify.conf

sudo systemctl restart k3s
sleep 15
sudo k3s kubectl get nodes
```

### Fix: Memory Pressure (if OOM kills crash the API server)

With 15GB RAM, the full DOME stack is tight. Consumer Keycloak is the largest Java process and is not needed for testing provider-side registration:

```bash
# Scale down consumer Keycloak to free ~500MB
sudo k3s kubectl scale statefulset consumer-keycloak -n consumer --replicas=0
free -h
```

> **Note:** Use `sudo k3s kubectl` instead of plain `kubectl` if the regular kubeconfig keeps timing out. Both point to the same cluster (`https://127.0.0.1:6443`).

---

## Fix 1: Set the Registration URL Env Var

This is the core fix. It sets `BAE_LP_DOME_REGISTER` on the logic proxy StatefulSet so the "Register" button points to the local Provider Keycloak registration page:

```bash
sudo k3s kubectl set env statefulset/provider-biz-ecosystem-logic-proxy \
  BAE_LP_DOME_REGISTER="https://keycloak-provider.192.168.120.128.nip.io/realms/test-realm/protocol/openid-connect/registrations?client_id=marketplace&redirect_uri=https://marketplace.192.168.120.128.nip.io&response_type=code" \
  -n provider -c marketplace-biz-ecosystem-logic-proxy
```

Then restart the pod:

```bash
sudo k3s kubectl delete pod provider-biz-ecosystem-logic-proxy-0 -n provider

# Wait for it to come back (takes 1–3 minutes)
until sudo k3s kubectl get pod provider-biz-ecosystem-logic-proxy-0 -n provider \
  | grep -q "1/1.*Running"; do sleep 5; done && echo "Pod ready"
```

**Verification:** Click Register on the marketplace dashboard. The browser should now navigate to `keycloak-provider.192.168.120.128.nip.io` instead of `dome-marketplace.github.io`.

---

## Fix 2: Enable Registration in Keycloak

By default the `test-realm` does not have `registrationAllowed: true`. The Keycloak admin password is stored inside the container (not in an env var), so we read it via `crictl` and use `nsenter` to call the admin API over localhost, bypassing the ingress entirely:

```bash
# Step 1: Find the provider Keycloak container ID and PID
KC_ID=$(sudo crictl ps | grep "keycloak" | grep -v "wait\|init\|consumer\|verifier" | awk '{print $1}' | head -1)
KC_PID=$(sudo crictl inspect $KC_ID | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['pid'])")
echo "KC container: $KC_ID  PID: $KC_PID"

# Step 2: Read the admin password from the container filesystem
ADMIN_PASS=$(sudo nsenter -t $KC_PID -m -- cat /opt/bitnami/keycloak/secrets/keycloak-admin)
echo "Admin pass: $ADMIN_PASS"

# Step 3: Get an admin token
TOKEN=$(sudo nsenter -t $KC_PID -n -- curl -s -X POST \
  "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=keycloak-admin&password=${ADMIN_PASS}&grant_type=password&client_id=admin-cli" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
echo "Token obtained: ${TOKEN:0:20}..."

# Step 4: Enable self-registration on the test-realm
sudo nsenter -t $KC_PID -n -- curl -s -X PUT \
  "http://localhost:8080/admin/realms/test-realm" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registrationAllowed": true, "registrationEmailAsUsername": true}'
echo "Registration enabled"
```

> **Note:** The admin password changes every time the Keycloak pod restarts (it is regenerated from a Kubernetes secret on startup). Always re-read it from the running container rather than hardcoding it. Step 1–3 above must be re-run after any Keycloak pod restart before step 4 will work.

---

## Fix 3: Create the `marketplace` Keycloak Client

The registration URL uses `client_id=marketplace`. This client does not exist in `test-realm` by default — the chart only creates a `did:web:fancy-marketplace.biz` client. Without the `marketplace` client, Keycloak returns 404 for the registration endpoint.

Using the `TOKEN` and `KC_PID` variables obtained in Fix 2:

```bash
sudo nsenter -t $KC_PID -n -- curl -s -w "\nHTTP:%{http_code}" -X POST \
  "http://localhost:8080/admin/realms/test-realm/clients" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "marketplace",
    "enabled": true,
    "publicClient": true,
    "standardFlowEnabled": true,
    "redirectUris": [
      "https://marketplace.192.168.120.128.nip.io/*",
      "https://marketplace.192.168.120.128.nip.io"
    ],
    "webOrigins": ["https://marketplace.192.168.120.128.nip.io"]
  }'
```

Expected response: `HTTP:201` (created). If you see `HTTP:409`, the client already exists from a previous run — that is fine, no action needed.

---

## Fix 4: Verify Traefik Is Routing Keycloak Correctly

After any large-scale pod restart (e.g., OOM recovery, K3s restart), Traefik in the `infra` namespace may start before the K3s API is fully ready and miss ingress rules. Restart it once K3s is stable:

```bash
sudo k3s kubectl rollout restart deployment traefik -n infra
sudo k3s kubectl rollout status deployment traefik -n infra --timeout=60s
```

Test the Keycloak route is reachable through the Squid proxy:

```bash
curl -x http://192.168.120.128:8888 -sk -o /dev/null -w "%{http_code}" \
  "https://keycloak-provider.192.168.120.128.nip.io/realms/test-realm"
echo ""
# Expected: 200
```

If this returns 404, Traefik has no route. Check:

```bash
# Confirm the ingress still exists
sudo k3s kubectl get ingress provider-keycloak -n provider

# If missing, the Helm release needs to be re-synced
helm upgrade --reuse-values provider-common provider-common-1.0.0 -n provider 2>/dev/null || \
  echo "Re-apply the provider Helm chart to restore the ingress"
```

---

## End-to-End Test

Once all four fixes are applied:

1. Configure your browser to use HTTP proxy `192.168.120.128:8888`
2. Open `https://marketplace.192.168.120.128.nip.io/dashboard`
3. Click **Register**
4. Browser should redirect to: `https://keycloak-provider.192.168.120.128.nip.io/realms/test-realm/protocol/openid-connect/registrations?client_id=marketplace&...`
5. Accept any self-signed certificate warning
6. Keycloak shows a registration form — fill in email/password and submit
7. After registration, Keycloak redirects back to the marketplace

---

## Summary of All Changes

| Resource | Namespace | Change |
|---|---|---|
| `StatefulSet/provider-biz-ecosystem-logic-proxy` | `provider` | `BAE_LP_DOME_REGISTER` env var added, pointing to local Keycloak registration URL |
| `Keycloak realm/test-realm` | in-cluster (provider Keycloak) | `registrationAllowed: true` set via admin API |
| `Keycloak client/marketplace` | `test-realm` | Created as public client with marketplace redirect URIs |
| `Deployment/traefik` | `infra` | Rollout restart to reload ingress routes after pod churn |
| `StatefulSet/consumer-keycloak` | `consumer` | Scaled to 0 replicas to relieve memory pressure (optional, for testing only) |

---

## Root Causes

| Cause | Impact |
|---|---|
| `BAE_LP_DOME_REGISTER` not set | Register button always redirects to external DOME portal |
| Keycloak `test-realm` has `registrationAllowed: false` by default | Keycloak rejects registration requests even with correct client |
| No `marketplace` OIDC client in `test-realm` | Keycloak returns 404 for the registration endpoint |
| Keycloak ingress has `router.tls: "true"` | HTTP URLs fail silently with Traefik 404; must use HTTPS |
| Traefik can miss ingress rules if it starts before K3s API recovers | Routes disappear after cluster restarts/OOM events |

---

## Persistence Warning

The Keycloak changes (registration enabled, `marketplace` client) are written to the Keycloak PostgreSQL database and **survive pod restarts**. However, if the entire PostgreSQL PersistentVolume is lost (e.g., full redeployment), the changes must be re-applied from Fix 2 and Fix 3.

The `BAE_LP_DOME_REGISTER` env var on the StatefulSet is stored in Kubernetes and **survives pod restarts permanently** — it only needs to be applied once per deployment.

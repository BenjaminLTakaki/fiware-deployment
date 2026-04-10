# FIWARE Data Space Connector - Troubleshooting Guide

This guide covers common issues encountered during deployment and operation of the FIWARE Data Space Connector.

## Table of Contents

1. [Deployment Issues](#deployment-issues)
2. [Pod Status Issues](#pod-status-issues)
3. [Certificate Issues](#certificate-issues)
4. [Database Issues](#database-issues)
5. [Service Access Issues](#service-access-issues)
6. [Keycloak Issues](#keycloak-issues)
7. [Diagnostic Commands](#diagnostic-commands)

---

## Deployment Issues

### Maven Build Fails

**Symptoms:**
- Build fails with dependency resolution errors
- Certificate generation fails

**Solutions:**

1. Check Java version (requires Java 17):
   ```bash
   java -version
   ```

2. Clear Maven cache and retry:
   ```bash
   rm -rf ~/.m2/repository
   mvn clean install -Plocal -DskipTests -Ddocker.skip
   ```

3. Check disk space (minimum 100GB recommended):
   ```bash
   df -h
   ```

### K3s Installation Fails

**Symptoms:**
- K3s service not starting
- kubectl commands fail

**Solutions:**

1. Check system requirements (8 vCores, 24GB RAM):
   ```bash
   free -h
   nproc
   ```

2. Check K3s service status:
   ```bash
   sudo systemctl status k3s
   sudo journalctl -u k3s -f
   ```

3. Restart K3s:
   ```bash
   sudo systemctl restart k3s
   ```

---

## Pod Status Issues

### Pods Stuck in Init State

**Symptoms:**
- Pods show `Init:0/2` or similar status
- Pods never reach Running state

**Common Causes:**
1. Keycloak dependency check failing
2. Database not ready
3. Missing secrets or ConfigMaps

**Solutions:**

1. Check init container logs:
   ```bash
   kubectl logs <pod-name> -n <namespace> -c <init-container-name>
   ```

2. The deployment script includes a workaround for the Keycloak init container bug. If pods are still stuck:
   ```bash
   # Manually bypass the wait-for-keycloak init container
   kubectl patch deployment <deployment-name> -n <namespace> --type='json' -p='[
     {"op": "replace", "path": "/spec/template/spec/initContainers/0/command",
      "value": ["sh", "-c", "echo Bypassing; exit 0"]}
   ]'
   ```

### Pods in CrashLoopBackOff

**Symptoms:**
- Pod repeatedly restarts
- Status shows `CrashLoopBackOff`

**Solutions:**

1. Check pod logs:
   ```bash
   kubectl logs <pod-name> -n <namespace> --previous
   ```

2. Check pod events:
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. Check resource limits:
   ```bash
   kubectl top pods -n <namespace>
   ```

### Pods in ContainerCreating

**Symptoms:**
- Pods stuck in `ContainerCreating` state

**Common Causes:**
1. Missing secrets (especially TLS secrets)
2. PersistentVolumeClaim not bound
3. Image pull failures

**Solutions:**

1. Check for missing secrets:
   ```bash
   kubectl get secrets -n <namespace>
   kubectl describe pod <pod-name> -n <namespace> | grep -A5 "Events:"
   ```

2. Check PVC status:
   ```bash
   kubectl get pvc -n <namespace>
   ```

3. Verify local-wildcard secret exists:
   ```bash
   kubectl get secret local-wildcard -n infra
   ```

---

## Certificate Issues

### Certificate Verification Failures

**Symptoms:**
- `x509: certificate signed by unknown authority`
- TLS handshake failures

**Solutions:**

1. Verify CA certificate exists:
   ```bash
   ls -la /fiware/data-space-connector/helpers/certs/out/ca/certs/
   ```

2. Check certificate validity:
   ```bash
   openssl x509 -in /fiware/data-space-connector/helpers/certs/out/ca/certs/ca.cert.pem -text -noout
   ```

3. Use CA certificate with curl:
   ```bash
   curl --cacert /fiware/data-space-connector/helpers/certs/out/ca/certs/ca.cert.pem \
     -x localhost:8888 https://keycloak-provider.<IP>.nip.io/health
   ```

### Certificate Mismatch

**Symptoms:**
- Services unable to communicate
- SSL errors in logs

**Solutions:**

1. Regenerate certificates (requires full rebuild):
   ```bash
   cd /fiware/data-space-connector
   rm -rf helpers/certs/out
   mvn clean install -Plocal -DskipTests -Ddocker.skip
   ```

2. Update secrets:
   ```bash
   kubectl delete secret local-wildcard -n infra
   kubectl create secret tls local-wildcard \
     --cert=/fiware/data-space-connector/helpers/certs/out/client-consumer/certs/client-chain-bundle.cert.pem \
     --key=/fiware/data-space-connector/helpers/certs/out/client-consumer/private/client.key.pem \
     -n infra
   ```

---

## Database Issues

### Liquibase Lock Stuck

**Symptoms:**
- Credentials-config-service stuck with "Waiting for changelog lock"
- Database migrations not completing

**Solutions:**

1. Clear Liquibase lock in MySQL (consumer):
   ```bash
   MYSQL_PASS=$(kubectl get secret authentication-database-secret -n consumer \
     -o jsonpath='{.data.mysql-root-password}' | base64 -d)
   kubectl exec -n consumer authentication-mysql-0 -c mysql -- \
     mysql -u root -p"${MYSQL_PASS}" -e \
     "UPDATE ccsdb.DATABASECHANGELOGLOCK SET LOCKED=0, LOCKGRANTED=NULL, LOCKEDBY=NULL WHERE ID=1;"
   ```

2. Same for provider:
   ```bash
   MYSQL_PASS=$(kubectl get secret authentication-database-secret -n provider \
     -o jsonpath='{.data.mysql-root-password}' | base64 -d)
   kubectl exec -n provider authentication-mysql-0 -c mysql -- \
     mysql -u root -p"${MYSQL_PASS}" -e \
     "UPDATE ccsdb.DATABASECHANGELOGLOCK SET LOCKED=0, LOCKGRANTED=NULL, LOCKEDBY=NULL WHERE ID=1;"
   ```

### PostgreSQL Connection Issues

**Symptoms:**
- Services cannot connect to PostgreSQL
- Connection refused errors

**Solutions:**

1. Check PostgreSQL pod status:
   ```bash
   kubectl get pods -n <namespace> -l app=postgres
   ```

2. Check PostgreSQL logs:
   ```bash
   kubectl logs -n <namespace> -l app=postgres
   ```

3. Verify database credentials:
   ```bash
   kubectl get secret -n <namespace> -o yaml | grep -A10 postgres
   ```

---

## Service Access Issues

### Services Not Accessible via Proxy

**Symptoms:**
- curl returns connection refused
- Services not responding

**Solutions:**

1. Verify squid proxy is running:
   ```bash
   kubectl get pods -n infra -l app=squid
   ```

2. Test proxy connectivity:
   ```bash
   curl -x localhost:8888 http://example.com
   ```

3. Check Traefik ingress:
   ```bash
   kubectl get ingress -A
   kubectl logs -n infra -l app=traefik
   ```

### DNS Resolution Failures

**Symptoms:**
- `Could not resolve host` errors
- `.nip.io` domains not resolving

**Solutions:**

1. Test DNS resolution:
   ```bash
   nslookup keycloak-provider.<IP>.nip.io
   ```

2. Check if IP is correct:
   ```bash
   echo $INTERNAL_IP
   hostname -I
   ```

3. Use direct IP if nip.io fails:
   ```bash
   # Add entries to /etc/hosts as fallback
   echo "<IP> keycloak-provider.<IP>.nip.io" | sudo tee -a /etc/hosts
   ```

---

## Keycloak Issues

### Keycloak Not Starting

**Symptoms:**
- Keycloak pods in Error or CrashLoopBackOff state
- Health check failing

**Solutions:**

1. Check Keycloak logs:
   ```bash
   kubectl logs -n provider -l app.kubernetes.io/name=keycloak
   ```

2. Increase heap size if OOM:
   ```bash
   kubectl set env deployment/keycloak -n provider KC_HEAP_SIZE=2048m
   ```

3. Check database connectivity:
   ```bash
   kubectl exec -n provider -it <keycloak-pod> -- /opt/bitnami/keycloak/bin/kcadm.sh config credentials
   ```

### Token Endpoint Not Working

**Symptoms:**
- Cannot obtain access tokens
- Authentication failures

**Solutions:**

1. Verify realm exists:
   ```bash
   curl -k -x localhost:8888 https://keycloak-consumer.<IP>.nip.io/realms/test-realm
   ```

2. Check client configuration:
   ```bash
   # Access Keycloak admin console
   curl -k -x localhost:8888 https://keycloak-consumer.<IP>.nip.io/admin/
   ```

---

## Diagnostic Commands

### Quick Health Check

```bash
# Check all pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Check recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Check node resources
kubectl top nodes
kubectl top pods -A
```

### Service Connectivity Test

```bash
#!/bin/bash
INTERNAL_IP=$(hostname -I | awk '{print $1}')
CA_CERT="/fiware/data-space-connector/helpers/certs/out/ca/certs/ca.cert.pem"

services=(
  "keycloak-provider"
  "keycloak-consumer"
  "scorpio-provider"
  "tir"
  "pap-provider"
)

for svc in "${services[@]}"; do
  echo -n "Testing $svc... "
  code=$(curl -s --cacert "$CA_CERT" -x localhost:8888 \
    -o /dev/null -w "%{http_code}" \
    "https://${svc}.${INTERNAL_IP}.nip.io/health" 2>/dev/null || echo "000")
  echo "HTTP $code"
done
```

### Full Diagnostic Report

```bash
#!/bin/bash
echo "=== FIWARE Diagnostic Report ==="
echo "Date: $(date)"
echo ""

echo "=== Node Status ==="
kubectl get nodes -o wide

echo ""
echo "=== Pod Status (Non-Running) ==="
kubectl get pods -A | grep -v Running | grep -v Completed

echo ""
echo "=== Recent Events ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

echo ""
echo "=== Resource Usage ==="
kubectl top nodes 2>/dev/null || echo "Metrics not available"

echo ""
echo "=== PVC Status ==="
kubectl get pvc -A

echo ""
echo "=== Ingress Status ==="
kubectl get ingress -A
```

---

## Getting Help

If you're still experiencing issues:

1. Check the FIWARE documentation: https://fiware-data-space-connector.readthedocs.io/
2. Review deployment logs: `/fiware/build.log`
3. Open an issue: https://github.com/FIWARE/data-space-connector/issues

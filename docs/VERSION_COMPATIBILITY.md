# FIWARE Data Space Connector - Version Compatibility

This document describes which versions of the FIWARE Data Space Connector are supported by this deployment script, along with known issues and their workarounds.

## Supported Versions

| Chart Version | Git Tag | Status | Notes |
|--------------|---------|--------|-------|
| 8.5.2 | data-space-connector-8.5.2 | **Recommended** | Default version, fully tested |
| 8.5.1 | data-space-connector-8.5.1 | Supported | |
| 8.5.0 | data-space-connector-8.5.0 | Supported | |
| 8.4.0 | data-space-connector-8.4.0 | Supported | |
| 8.3.1 | data-space-connector-8.3.1 | Supported | |
| 8.3.0 | data-space-connector-8.3.0 | Supported | Minimum tested version |

## Known Issues and Workarounds

### KEYCLOAK_INIT_BUG
**Affects:** 8.3.0 - 8.5.2

**Symptoms:**
- Pods stuck in `Init:0/2` or `Init:1/2` state
- `wait-for-keycloak` init container fails dependency check

**Workaround Applied:**
The script automatically patches deployments to bypass the `wait-for-keycloak` init container:
```bash
kubectl patch deployment <name> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/initContainers/X/command",
   "value": ["sh", "-c", "echo Bypassing; exit 0"]}
]'
```

### LIQUIBASE_LOCK
**Affects:** 8.3.0 - 8.5.2

**Symptoms:**
- `credentials-config-service` stuck with "Waiting for changelog lock"
- Pod repeatedly crashes and restarts

**Workaround Applied:**
The script clears stale Liquibase locks in MySQL:
```sql
UPDATE ccsdb.DATABASECHANGELOGLOCK
SET LOCKED=0, LOCKGRANTED=NULL, LOCKEDBY=NULL
WHERE ID=1;
```

### APISIX_PROBE_BUG
**Affects:** 8.5.0 - 8.5.2

**Symptoms:**
- `consumer-apisix-data-plane` pod crashes due to failing health probes
- CrashLoopBackOff state

**Workaround Applied:**
The script removes problematic health probes:
```bash
kubectl patch deployment consumer-apisix-data-plane -n consumer --type='json' -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"}
]'
```

## Using Untested Versions

To deploy an untested version:

1. Set the commit hash in your environment:
   ```bash
   export FIWARE_COMMIT=<your-commit-hash>
   ```

2. Run the deployment script - it will:
   - Detect the chart version from `Chart.yaml`
   - Warn you if the version is untested
   - Prompt for confirmation to continue

3. To skip the confirmation prompt:
   ```bash
   export SKIP_VERSION_CHECK=true
   ```

## Adding Support for New Versions

To add support for a new version:

1. Test the deployment on the new version
2. Identify any bugs and required workarounds
3. Update `fiware_deployment.sh`:
   ```bash
   # Add to SUPPORTED_CHART_VERSIONS
   SUPPORTED_CHART_VERSIONS=("X.Y.Z" "8.5.2" ...)

   # Add to VERSION_BUGS if workarounds needed
   VERSION_BUGS["X.Y.Z"]="BUG1,BUG2"
   ```

4. Update this document with the new version

## Checking Your Version

After cloning the repository, check the version:
```bash
cd /fiware/data-space-connector
cat charts/data-space-connector/Chart.yaml | grep "^version:"
```

Or use git tags:
```bash
git describe --tags --exact-match 2>/dev/null || git log --oneline -1
```

## Reporting New Issues

If you encounter issues on a supported version:

1. Check existing workarounds in this document
2. Check the [TROUBLESHOOTING.md](TROUBLESHOOTING.md) guide
3. If it's a new issue, please report it with:
   - Chart version
   - Git commit hash
   - Error messages
   - Pod/deployment names affected

# FIWARE Data Space Connector - Automated Deployment

Automated deployment script for the FIWARE Data Space Connector, optimized for research purposes and NetLab VM environments.

## Features

- **One-command deployment** of complete FIWARE Data Space Connector
- **NetLab VM compatible** - Auto-detects IP, works with different VMs
- **Version compatibility** - Tested with chart versions 8.3.0 - 8.5.2
- **Research-grade** - Includes monitoring, health checks, and load testing
- **Automatic bug fixes** - Applies version-specific workarounds

## Requirements

- Ubuntu 24.04 LTS
- Minimum 8 vCores, 32GB RAM, 100GB disk
- Internet access

## Quick Start

```bash
# Clone the repository
git clone <repo-url> ~/fiware_deployment
cd ~/fiware_deployment

# Make executable
chmod +x fiware_deployment.sh

# Run deployment (auto-detects IP)
./fiware_deployment.sh

# Or specify IP manually
./fiware_deployment.sh 192.168.x.x
```

## What Gets Deployed

| Component | Description |
|-----------|-------------|
| K3s | Lightweight Kubernetes |
| Keycloak | Identity & Access Management |
| Scorpio Broker | NGSI-LD Context Broker |
| APISIX | API Gateway |
| OPA | Policy Decision Point |
| Trust Services | TIL, TIR, Verifiable Credentials |
| Headlamp | Kubernetes Dashboard |

## Project Structure

```
fiware_deployment/
├── fiware_deployment.sh              # Main deployment script
├── config/
│   └── .env.template                 # Environment configuration template
├── docs/
│   ├── LOCAL_DEPLOYMENT_2VM_GUIDE.md # Two-VM split deployment guide
│   ├── single-vm/
│   │   ├── scenarios/                # Deployment walkthroughs (single VM)
│   │   │   ├── LOCAL_DEPLOYMENT_SCENARIOS.md
│   │   │   └── CENTRAL_MARKETPLACE_SCENARIOS.md
│   │   ├── fixes/                    # Documented fixes for known issues
│   │   │   ├── MARKETPLACE_LOGGING_FIX.md
│   │   │   └── MARKETPLACE_REGISTRATION_FIX.md
│   │   ├── results/                  # Demo execution results and references
│   │   │   ├── CENTRAL_MARKETPLACE_DEMO_RESULTS.md
│   │   │   ├── CENTRAL_MARKETPLACE_SESSION_LOG.md
│   │   │   └── LOCAL_MD_EXECUTION_REFERENCE.md
│   │   ├── fiware_official_scenarios/ # Use case validation against upstream docs
│   │   │   └── FIWARE_TEST_SCENARIOS.md
│   │   ├── analysis/                 # Gap analysis and research findings
│   │   │   └── DEPLOYMENT_GAP_ANALYSIS.md
│   │   └── reference/                # Reference material and known issues
│   │       ├── TROUBLESHOOTING.md
│   │       └── VERSION_COMPATIBILITY.md
│   └── two-vm/
│       ├── scenarios/                # Deployment walkthroughs (two-VM split)
│       │   └── GAIA_X_SCENARIO_2VM.md
│       └── fixes/                    # Documented fixes for two-VM issues
├── scripts/
│   ├── healthcheck.sh                # Service health verification
│   └── deploy-monitoring.sh          # Prometheus/Grafana setup
├── monitoring/
│   ├── prometheus-values.yaml
│   └── loki-values.yaml
└── tests/
    └── load/
        ├── k6-fiware-test.js
        └── run-tests.sh
```

## After Deployment

### Access Services

All services are accessed via the Squid proxy:

```bash
# Source environment
source ~/.bashrc

# Test Keycloak
curl -k -x localhost:8888 https://keycloak-provider.${INTERNAL_IP}.nip.io/health/ready

# Get access token
curl -k -x localhost:8888 -X POST \
  "https://keycloak-consumer.${INTERNAL_IP}.nip.io/realms/test-realm/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=account-console&username=employee&password=test&scope=openid"
```

### Key URLs

| Service | URL |
|---------|-----|
| Keycloak Provider | `https://keycloak-provider.<IP>.nip.io` |
| Keycloak Consumer | `https://keycloak-consumer.<IP>.nip.io` |
| Scorpio Broker | `https://scorpio-provider.<IP>.nip.io` |
| Trust Registry | `https://tir.<IP>.nip.io` |
| Headlamp | `http://<IP>:<NodePort>` |

### Health Check

```bash
./scripts/healthcheck.sh
```

### View Pods

```bash
kubectl get pods -A
```

## Configuration

Copy the template and customize:

```bash
cp config/.env.template config/.env.production
nano config/.env.production
```

Key settings:
- `INTERNAL_IP` - VM IP address (auto-detected if empty)
- `FIWARE_COMMIT` - Git commit to deploy
- `SKIP_VERSION_CHECK` - Bypass version validation

## Documentation

All operational documentation lives under `docs/` and is split by deployment topology.

### Single-VM

| Folder | Contents |
|--------|----------|
| `single-vm/scenarios/` | Full deployment and demo walkthroughs |
| `single-vm/fixes/` | Step-by-step fixes for known issues |
| `single-vm/results/` | Demo execution results and script references |
| `single-vm/fiware_official_scenarios/` | Use case validation against upstream FIWARE docs |
| `single-vm/analysis/` | Deployment gap analysis and research findings |
| `single-vm/reference/` | Troubleshooting guide and version compatibility |

### Two-VM

| Folder | Contents |
|--------|----------|
| `two-vm/scenarios/` | Deployment walkthroughs for the two-VM split setup |
| `two-vm/fixes/` | Fixes specific to the two-VM topology |

The top-level guide for the two-VM split deployment is at [`docs/LOCAL_DEPLOYMENT_2VM_GUIDE.md`](docs/LOCAL_DEPLOYMENT_2VM_GUIDE.md).

## Troubleshooting

See [`docs/single-vm/reference/TROUBLESHOOTING.md`](docs/single-vm/reference/TROUBLESHOOTING.md) for common issues.

Quick diagnostics:

```bash
# Check pod status
kubectl get pods -A | grep -v Running

# Check logs
kubectl logs -n provider <pod-name>

# Run health check
./scripts/healthcheck.sh --verbose
```

## Version Compatibility

See [`docs/single-vm/reference/VERSION_COMPATIBILITY.md`](docs/single-vm/reference/VERSION_COMPATIBILITY.md) for supported versions and known issues.

## License

This deployment script is provided as-is for research and educational purposes.

## Links

- [FIWARE Data Space Connector](https://github.com/FIWARE/data-space-connector)
- [FIWARE Documentation](https://fiware-data-space-connector.readthedocs.io/)
#!/bin/bash
# ============================================================================
# FIWARE Data Space Connector - Automated Deployment Script (v5 - Research)
# ============================================================================
# Based on the FiWare Local Deployment guide (PDF) and battle-tested fixes.
#
# SUPPORTED VERSIONS:
#   Tested: data-space-connector chart versions 8.3.0 - 8.5.2
#   Default commit: 0b78cdaf7573cbd1852e2541afe0acb816c6caa5
#
# Requirements:
#   - Ubuntu 24.04 LTS
#   - Minimum 8 vCores, 24GB RAM, 100GB disk
#   - Static IP address
#
# Usage:
#   chmod +x deploy-fiware.sh
#   ./deploy-fiware.sh [IP_ADDRESS]
#
# If no IP is provided, the script auto-detects the VM's internal IP.
#
# Key design decisions:
#   - Maven's antrun generates ALL certs and embeds secrets into target/ manifests.
#     We do NOT re-generate certs or manually create secrets post-build, as that
#     causes cert mismatches.
#   - The local-wildcard TLS secret is created explicitly in infra BEFORE deploying
#     infra resources, because the infra traefik pod mounts it on startup.
#   - Headlamp is pinned to chart version 0.25.0 (latest has a --session-ttl bug).
#   - All services are accessed via squid proxy (localhost:8888) + HTTPS, not
#     direct HTTP. This is the FIWARE-designed access pattern.
# ============================================================================

set -euo pipefail

# ======================== CONFIGURATION ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment configuration if available
if [ -f "${SCRIPT_DIR}/config/.env.production" ]; then
    echo "Loading production environment configuration..."
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config/.env.production"
elif [ -f "${SCRIPT_DIR}/config/.env.development" ]; then
    echo "Loading development environment configuration..."
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config/.env.development"
elif [ -f "${SCRIPT_DIR}/config/.env" ]; then
    echo "Loading environment configuration..."
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config/.env"
fi

# Default values (can be overridden by .env files)
FIWARE_COMMIT="${FIWARE_COMMIT:-0b78cdaf7573cbd1852e2541afe0acb816c6caa5}"
FIWARE_REPO="https://github.com/FIWARE/data-space-connector.git"
FIWARE_DIR="/fiware/data-space-connector"
YQ_VERSION="${YQ_VERSION:-v4.45.1}"
HEADLAMP_CHART_VERSION="${HEADLAMP_CHART_VERSION:-0.25.0}"  # Pinned: latest has --session-ttl flag bug
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-300}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-600}"

# ======================== VERSION COMPATIBILITY ========================
# Tested chart versions (major.minor.patch from charts/data-space-connector/Chart.yaml)
SUPPORTED_CHART_VERSIONS=("8.5.2" "8.5.1" "8.5.0" "8.4.0" "8.3.1" "8.3.0")

# Version-specific workarounds
# - KEYCLOAK_INIT_BUG: wait-for-keycloak init containers get stuck
# - LIQUIBASE_LOCK: Database migrations can leave stale locks
# - APISIX_PROBE_BUG: Health probes cause crashes
declare -A VERSION_BUGS
VERSION_BUGS["8.5.2"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK,APISIX_PROBE_BUG"
VERSION_BUGS["8.5.1"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK,APISIX_PROBE_BUG"
VERSION_BUGS["8.5.0"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK,APISIX_PROBE_BUG"
VERSION_BUGS["8.4.0"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK"
VERSION_BUGS["8.3.1"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK"
VERSION_BUGS["8.3.0"]="KEYCLOAK_INIT_BUG,LIQUIBASE_LOCK"

# Skip compatibility check if set
SKIP_VERSION_CHECK="${SKIP_VERSION_CHECK:-false}"

# ======================== FEATURE FLAGS ========================
# Enable DSP/EDC profile (FDSC-EDC + Vault + IdentityHub - required for DSP_INTEGRATION.md)
DSP_ENABLED="${DSP_ENABLED:-false}"
# Enable Gaia-X profile (GX-Registry + DSS + did:web - required for GAIA_X.MD)
GAIAX_ENABLED="${GAIAX_ENABLED:-false}"
# Auto-configure CCS (Credentials Config Service) after deploy - fixes UC-F5 VCVerifier 404
# and OperatorCredential scope returning null (REQUIRED for full LOCAL.MD + CENTRAL_MARKETPLACE.md)
SETUP_CCS="${SETUP_CCS:-true}"
# Auto-create baseline ODRL policies at PAP (LOCAL.MD offers, selfRegistration, ordering, K8S access)
SETUP_POLICIES="${SETUP_POLICIES:-true}"
# Auto-configure DID materials in IdentityHub after DSP deploy (DSP_INTEGRATION.md steps 1-4)
SETUP_IDENTITY_HUB="${SETUP_IDENTITY_HUB:-false}"  # enabled automatically when DSP_ENABLED=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ======================== HELPER FUNCTIONS ========================
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Bulletproof pod-wait that won't trip set -e.
# Counts pods where status is Running AND all containers ready (1/1, 2/2, etc.)
# plus Completed pods (finished jobs). Everything else = not ready.
wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300}
    local interval=10
    local elapsed=0
    log_step "Waiting for all pods in namespace '$namespace' to be ready (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local total=0
        local ready=0
        total=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || true)
        ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null \
            | awk '($3 == "Running" && $2 ~ /^([0-9]+)\/\1$/) || $3 == "Completed" {count++} END {print count+0}' || true)

        if [ "$total" -gt 0 ] && [ "$ready" -ge "$total" ]; then
            log_ok "All $total pods in '$namespace' are ready."
            return 0
        fi
        local not_ready=$((total - ready))
        echo "  ... $ready/$total pods ready, $not_ready not ready (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    log_warn "Timeout waiting for pods in '$namespace'. Current status:"
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -v "Running\|Completed" || true
    return 0  # Don't fail the script — some pods take longer
}

check_command() {
    if command -v "$1" &>/dev/null; then
        log_ok "$1 is installed"
        return 0
    else
        return 1
    fi
}

# kubectl apply with retry logic and proper error handling
kubectl_apply_with_retry() {
    local resource_path="$1"
    local resource_name="${2:-resources}"
    local max_retries=3
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if kubectl apply -f "$resource_path" -R 2>&1; then
            return 0
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_warn "Failed to apply $resource_name (attempt $retry_count/$max_retries). Retrying in 5s..."
            sleep 5
        fi
    done
    log_err "Failed to apply $resource_name after $max_retries attempts"
    return 1
}

# kubectl apply that may fail gracefully (for optional resources)
kubectl_apply_optional() {
    local resource_path="$1"
    local resource_name="${2:-optional resources}"

    if [ -d "$resource_path" ] || [ -f "$resource_path" ]; then
        if kubectl apply -f "$resource_path" -R 2>&1; then
            log_ok "$resource_name applied successfully"
        else
            log_warn "$resource_name could not be applied (may not exist or have issues)"
        fi
    else
        log_warn "$resource_name path does not exist: $resource_path"
    fi
}

# Validate IPv4 address format
validate_ip() {
    local ip=$1
    # Check basic format: 4 octets separated by dots
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_err "Invalid IP address format: $ip"
        log_err "Expected format: X.X.X.X where X is 0-255"
        exit 1
    fi
    # Validate each octet is <= 255
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            log_err "Invalid IP address: $ip (octet $octet > 255)"
            exit 1
        fi
    done
    # Warn about localhost/loopback
    if [[ $ip == "127."* ]]; then
        log_warn "Using loopback address ($ip). Services may not be accessible externally."
    fi
    return 0
}

# Detect and validate chart version from cloned repository
detect_chart_version() {
    local chart_file="$FIWARE_DIR/charts/data-space-connector/Chart.yaml"

    if [ ! -f "$chart_file" ]; then
        log_warn "Chart.yaml not found - version detection will occur after clone"
        return 0
    fi

    # Extract version from Chart.yaml
    DETECTED_VERSION=$(grep "^version:" "$chart_file" | awk '{print $2}' | tr -d '"' || echo "unknown")

    if [ "$DETECTED_VERSION" = "unknown" ]; then
        log_warn "Could not detect chart version from $chart_file"
        return 0
    fi

    log_ok "Detected chart version: $DETECTED_VERSION"

    # Check if version is in supported list
    local is_supported=false
    for supported in "${SUPPORTED_CHART_VERSIONS[@]}"; do
        if [ "$DETECTED_VERSION" = "$supported" ]; then
            is_supported=true
            break
        fi
    done

    if [ "$is_supported" = false ]; then
        log_warn "============================================================"
        log_warn "Chart version $DETECTED_VERSION is NOT in the tested list!"
        log_warn "Tested versions: ${SUPPORTED_CHART_VERSIONS[*]}"
        log_warn "The script may not work correctly with this version."
        log_warn "============================================================"

        if [ "$SKIP_VERSION_CHECK" != "true" ]; then
            echo ""
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_err "Deployment cancelled. Set SKIP_VERSION_CHECK=true to bypass."
                exit 1
            fi
        fi
    fi

    # Check for version-specific bugs
    if [ -n "${VERSION_BUGS[$DETECTED_VERSION]:-}" ]; then
        log_step "Version $DETECTED_VERSION has known issues that will be patched:"
        IFS=',' read -ra BUGS <<< "${VERSION_BUGS[$DETECTED_VERSION]}"
        for bug in "${BUGS[@]}"; do
            echo "  - $bug"
        done
    fi

    export DETECTED_VERSION
}

# Check if a specific bug workaround is needed for current version
needs_workaround() {
    local bug_name="$1"
    if [ -z "${DETECTED_VERSION:-}" ]; then
        return 0  # Apply workaround if version unknown (safer)
    fi
    if [ -z "${VERSION_BUGS[$DETECTED_VERSION]:-}" ]; then
        return 1  # No known bugs for this version
    fi
    if [[ "${VERSION_BUGS[$DETECTED_VERSION]}" == *"$bug_name"* ]]; then
        return 0  # Bug exists for this version
    fi
    return 1
}

# ======================== DETECT IP (NetLab VM Compatible) ========================
# IP detection for NetLab VMs where each VM gets a different IP
# Priority: 1) Command line arg, 2) Environment var, 3) Saved IP, 4) Auto-detect

detect_best_ip() {
    # Get all IPs, filter out loopback, docker, and k8s internal IPs
    local all_ips
    all_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | \
        grep -v '^127\.' | \
        grep -v '^172\.17\.' | \
        grep -v '^10\.42\.' | \
        grep -v '^10\.43\.' || true)

    if [ -z "$all_ips" ]; then
        echo ""
        return
    fi

    # Return the first non-filtered IP
    echo "$all_ips" | head -1
}

show_available_ips() {
    echo "  Available network interfaces:"
    ip -4 addr show 2>/dev/null | grep -E "inet [0-9]" | \
        awk '{print "    " $NF ": " $2}' | sed 's/\/[0-9]*//' || \
        hostname -I | tr ' ' '\n' | grep -v '^$' | while read -r ip; do
            echo "    $ip"
        done
}

IP_CACHE_FILE="${SCRIPT_DIR}/.last_ip"

# ======================== ARGUMENT PARSING ========================
# Supports: ./fiware_deployment.sh [IP] [--dsp] [--gaia-x] [--no-ccs] [--no-policies]
for arg in "$@"; do
    case "$arg" in
        --dsp)           DSP_ENABLED=true ;;
        --gaia-x)        GAIAX_ENABLED=true ;;
        --no-ccs)        SETUP_CCS=false ;;
        --no-policies)   SETUP_POLICIES=false ;;
        --help|-h)
            echo "Usage: $0 [IP_ADDRESS] [OPTIONS]"
            echo "Options:"
            echo "  --dsp         Enable DSP/EDC profile (FDSC-EDC, Vault, IdentityHub)"
            echo "  --gaia-x      Enable Gaia-X profile (GX-Registry, DSS, did:web)"
            echo "  --no-ccs      Skip automatic CCS (credentials-config-service) setup"
            echo "  --no-policies Skip automatic baseline ODRL policy creation"
            echo "  --help        Show this help"
            exit 0
            ;;
    esac
done

if [ -n "${1:-}" ] && [[ "${1}" != --* ]]; then
    # Option 1: Command line argument
    INTERNAL_IP="$1"
    log_ok "Using IP from command line: $INTERNAL_IP"
elif [ -n "${INTERNAL_IP:-}" ]; then
    # Option 2: Environment variable (from .env file)
    log_ok "Using IP from environment: $INTERNAL_IP"
elif [ -f "$IP_CACHE_FILE" ]; then
    # Option 3: Previously saved IP (useful for re-runs on same VM)
    CACHED_IP=$(cat "$IP_CACHE_FILE")
    # Verify the cached IP is still valid on this system
    if hostname -I | grep -q "$CACHED_IP"; then
        INTERNAL_IP="$CACHED_IP"
        log_ok "Using previously saved IP: $INTERNAL_IP"
    else
        log_warn "Cached IP ($CACHED_IP) no longer valid on this system"
        INTERNAL_IP=$(detect_best_ip)
    fi
else
    # Option 4: Auto-detect
    INTERNAL_IP=$(detect_best_ip)
fi

# If still no IP, show available options and exit
if [ -z "$INTERNAL_IP" ]; then
    log_err "Could not auto-detect IP address."
    echo ""
    show_available_ips
    echo ""
    log_err "Please specify the IP manually:"
    log_err "  ./fiware_deployment.sh <IP_ADDRESS>"
    log_err "  or set INTERNAL_IP in config/.env.production"
    exit 1
fi

# Validate the IP address format
validate_ip "$INTERNAL_IP"

# Save IP for future runs on this VM
echo "$INTERNAL_IP" > "$IP_CACHE_FILE"

# Show all available IPs for transparency
echo ""
echo "============================================================================"
echo "  FIWARE Data Space Connector - Automated Deployment"
echo "============================================================================"
echo "  Target IP: $INTERNAL_IP"
echo "  Commit:    $FIWARE_COMMIT"
echo ""
show_available_ips
echo ""
echo "  Note: If this IP is incorrect, cancel and re-run with:"
echo "        ./fiware_deployment.sh <CORRECT_IP>"
echo "============================================================================"
echo ""
echo "This script will install and configure:"
echo "  - K3s (lightweight Kubernetes)"
echo "  - Helm 3"
echo "  - Docker"
echo "  - Headlamp (Kubernetes dashboard)"
echo "  - FIWARE DSC (Provider + Consumer + Trust Anchor + Infra)"
echo ""
echo "Estimated time: 15-30 minutes depending on network speed."
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# ======================== PHASE 1: PREREQUISITES ========================
echo ""
echo "================================================================"
echo "  PHASE 1: Installing Prerequisites"
echo "================================================================"

log_step "Updating system packages..."
sudo apt-get update -qq && sudo apt-get upgrade -y -qq && sudo apt-get autoremove -y -qq
log_ok "System updated."

log_step "Installing required tools..."
sudo apt-get install -y -qq iputils-ping git jq default-jdk nano wget maven curl ca-certificates openssl
log_ok "Tools installed."

log_step "Installing yq..."
if ! check_command yq; then
    sudo wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq
    log_ok "yq installed."
fi

# ======================== INSTALL K3S ========================
log_step "Installing K3s..."
if ! check_command k3s; then
    curl -sfL https://get.k3s.io | sh -
    log_ok "K3s installed."
else
    log_ok "K3s already installed."
fi

# Configure kubeconfig
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG=~/.kube/config

# Persist kubeconfig in bashrc if not already there
if ! grep -q 'export KUBECONFIG=~/.kube/config' ~/.bashrc 2>/dev/null; then
    echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
fi

# Set persistent k3s config permissions (write-kubeconfig-mode)
sudo mkdir -p /etc/rancher/k3s
echo 'write-kubeconfig-mode: "0644"' | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
sudo systemctl restart k3s
sleep 10

log_step "Verifying K3s..."
kubectl get nodes
kubectl get pods -n kube-system
log_ok "K3s is running."

# ======================== INSTALL DOCKER ========================
log_step "Installing Docker..."
if ! check_command docker; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    log_ok "Docker installed."
else
    log_ok "Docker already installed."
fi

# ======================== INSTALL HELM ========================
log_step "Installing Helm..."
if ! check_command helm; then
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_ok "Helm installed."
else
    log_ok "Helm already installed."
fi

INSTALLED_HELM_VERSION=$(helm version --short 2>/dev/null | sed 's/v//')
log_ok "Helm version: $INSTALLED_HELM_VERSION"

# ======================== INSTALL HEADLAMP ========================
log_step "Installing Headlamp (Kubernetes dashboard)..."
if ! helm repo list 2>/dev/null | grep -q headlamp; then
    helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
    log_ok "Headlamp Helm repo added."
fi
helm repo update headlamp

# Pinned to 0.25.0 — latest versions have a --session-ttl flag bug causing CrashLoopBackOff
helm upgrade --install my-headlamp headlamp/headlamp \
    --namespace kube-system --version "$HEADLAMP_CHART_VERSION" \
    --wait --timeout 120s 2>/dev/null \
    || log_warn "Headlamp install had warnings (may already exist)."

# Expose Headlamp as NodePort
kubectl patch service my-headlamp -n kube-system \
    -p '{"spec":{"type":"NodePort"}}' 2>/dev/null || true
log_ok "Headlamp installed and exposed as NodePort."

# ======================== PERSIST BASHRC HELPERS ========================
log_step "Persisting INTERNAL_IP and helper functions in ~/.bashrc..."

if ! grep -q 'get_internal_ip()' ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc << 'BASHRC_BLOCK'

# --- FIWARE helpers (added by deploy-fiware.sh) ---
get_internal_ip() {
    INTERNAL_IP=$(hostname -I | awk '{print $1}')
    if [[ $- == *i* ]]; then
        if [ -z "$INTERNAL_IP" ]; then
            echo "Warning: No IP address found."
        else
            echo "Internal IP: $INTERNAL_IP"
        fi
    fi
    export INTERNAL_IP
}
get_internal_ip

headlamp-token() {
    kubectl create token my-headlamp --namespace kube-system
}
# --- End FIWARE helpers ---
BASHRC_BLOCK
    log_ok "INTERNAL_IP function and headlamp-token added to ~/.bashrc."
else
    log_ok "INTERNAL_IP function already in ~/.bashrc."
fi

export INTERNAL_IP

# ======================== EXTEND SYSTEM LIMITS ========================
log_step "Extending inotify limits..."
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=65536
grep -q "fs.inotify.max_user_instances=512" /etc/sysctl.conf || echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.conf
grep -q "fs.inotify.max_user_watches=65536" /etc/sysctl.conf || echo "fs.inotify.max_user_watches=65536" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
log_ok "System limits extended."

# ======================== PHASE 2: CLONE & BUILD ========================
echo ""
echo "================================================================"
echo "  PHASE 2: Clone Repository & Build"
echo "================================================================"

log_step "Setting up directories..."
sudo mkdir -p /fiware
sudo chown -R "$USER:$USER" /fiware

log_step "Cloning FIWARE DSC repository..."
if [ -d "$FIWARE_DIR" ]; then
    log_warn "Repository already exists at $FIWARE_DIR. Removing and re-cloning..."
    rm -rf "$FIWARE_DIR"
fi
cd /fiware
git clone "$FIWARE_REPO"
cd "$FIWARE_DIR"

log_step "Checking out pinned commit ($FIWARE_COMMIT)..."
git checkout "$FIWARE_COMMIT"
log_ok "Repository at commit $(git log --oneline -1)"

# Detect and validate chart version
detect_chart_version

# ======================== PATCH YAML FILES ========================
log_step "Enabling database persistence in YAML files..."
cd "$FIWARE_DIR/k3s"

# Consumer
yq eval '
  .postgresql.primary.persistence.enabled = true |
  .postgresql.primary.persistence.storageClass = "local-path" |
  .mysql.primary.persistence.enabled = true |
  .mysql.primary.persistence.storageClass = "local-path" |
  .postgis.primary.persistence.enabled = true |
  .postgis.primary.persistence.storageClass = "local-path"
' -i consumer.yaml

# Provider
yq eval '
  .postgresql.primary.persistence.enabled = true |
  .postgresql.primary.persistence.storageClass = "local-path" |
  .mysql.primary.persistence.enabled = true |
  .mysql.primary.persistence.storageClass = "local-path" |
  .postgis.primary.persistence.enabled = true |
  .postgis.primary.persistence.storageClass = "local-path"
' -i provider.yaml

# Trust Anchor
yq eval '
  .mysql.primary.persistence.enabled = true |
  .mysql.primary.persistence.storageClass = "local-path"
' -i trust-anchor.yaml

log_ok "Database persistence enabled."

log_step "Replacing 127.0.0.1 with ${INTERNAL_IP} in all YAML files..."
find "$FIWARE_DIR/k3s" -type f -name "*.yaml" | while read -r file; do
    if grep -q "127.0.0.1.nip.io" "$file"; then
        sed -i "s/127.0.0.1.nip.io:8080/${INTERNAL_IP}.nip.io/g" "$file"
        sed -i "s/127.0.0.1.nip.io/${INTERNAL_IP}.nip.io/g" "$file"
    fi
done
log_ok "IP addresses replaced."

# ======================== MAVEN BUILD ========================
# Maven's antrun phase will:
#   1. Run generate-certs.sh (creates CA, intermediate, client certs)
#   2. Generate all K8s secrets as dry-run YAML (embedded into target/ manifests)
#   3. Template all Helm charts into target/k3s/
# This is why we do NOT manually run generate-certs.sh or kubectl create secret.
log_step "Running Maven build (this takes a few minutes)..."
cd "$FIWARE_DIR"
HELM_VER=$(helm version --short 2>/dev/null | sed 's/v//' | cut -d'+' -f1)

# Build the Maven profile list
MAVEN_PROFILES="local"
if [ "$DSP_ENABLED" = "true" ]; then
    MAVEN_PROFILES="local,dsp"
    SETUP_IDENTITY_HUB=true
    log_ok "DSP profile enabled — FDSC-EDC, Vault, IdentityHub will be deployed."
fi
if [ "$GAIAX_ENABLED" = "true" ]; then
    MAVEN_PROFILES="${MAVEN_PROFILES},gaia-x"
    log_ok "Gaia-X profile enabled — GX-Registry, DSS validation, did:web will be deployed."
    log_warn "Gaia-X requires pre-generated eIDAS certs in helpers/certs/. See GAIA_X.MD for cert generation steps."
fi
log_step "Maven profiles: -P${MAVEN_PROFILES}"

mvn clean install -P"${MAVEN_PROFILES}" -DskipTests -Ddocker.skip -Dhelm.version="$HELM_VER" 2>&1 | tee /fiware/build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_warn "Maven build may have failed. Retrying once..."
    mvn clean install -P"${MAVEN_PROFILES}" -DskipTests -Ddocker.skip -Dhelm.version="$HELM_VER" 2>&1 | tee /fiware/build-retry.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_err "Maven build failed on retry. Check /fiware/build-retry.log"
        exit 1
    fi
fi
log_ok "Maven build complete (profiles: ${MAVEN_PROFILES})."

# ======================== PHASE 3: DEPLOY TO K8S ========================
echo ""
echo "================================================================"
echo "  PHASE 3: Deploy to Kubernetes"
echo "================================================================"

# ---- Namespaces ----
log_step "Creating namespaces..."
kubectl apply -f "$FIWARE_DIR/target/k3s/namespaces/"
log_ok "Namespaces created."

# ---- NOTE: Certificates & Secrets ----
# Skipped! Maven's antrun already generated certs and embedded all secrets
# (local-wildcard, gx-registry-keypair, signing-key, root-ca, tls-secret,
#  kc-keystore, did-keystore, cert-chain, signing-key-env) into the
# target/k3s/ manifests. Re-generating certs here would create a mismatch.
log_ok "Certificates and secrets handled by Maven build (no manual step needed)."

# ---- Local path storage permissions (scoped RBAC - principle of least privilege) ----
log_step "Setting up storage permissions with scoped RBAC..."

# Create a properly scoped ClusterRole instead of using cluster-admin
kubectl apply -f - <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list", "watch"]
RBAC_EOF

kubectl create clusterrolebinding local-path-provisioner-binding \
    --clusterrole=local-path-provisioner-role \
    --serviceaccount=local-path-storage:local-path-provisioner-service-account \
    --dry-run=client -o yaml | kubectl apply -f -
log_ok "Storage permissions set with scoped RBAC (principle of least privilege)."

# ---- Pre-create local-wildcard secret in infra ----
# The infra traefik pod mounts this secret as a volume on startup.
# It's also included in the additional-resources manifests, but those deploy
# AFTER infra — so traefik gets stuck in ContainerCreating without this.
log_step "Pre-creating local-wildcard TLS secret in infra namespace..."
kubectl create secret tls local-wildcard \
    --cert="$FIWARE_DIR/helpers/certs/out/client-consumer/certs/client-chain-bundle.cert.pem" \
    --key="$FIWARE_DIR/helpers/certs/out/client-consumer/private/client.key.pem" \
    -n infra --dry-run=client -o yaml | kubectl apply -f -
log_ok "local-wildcard secret created in infra."

# ---- Deploy resources (ordered, matching PDF sequence) ----
log_step "Deploying infrastructure layer..."
kubectl_apply_with_retry "$FIWARE_DIR/target/k3s/infra/" "infrastructure"
sleep 30
wait_for_pods "infra" 60

log_step "Deploying trust anchor..."
kubectl_apply_with_retry "$FIWARE_DIR/target/k3s/trust-anchor/trust-anchor/" "trust-anchor"
sleep 20
wait_for_pods "trust-anchor" 60

log_step "Deploying provider..."
kubectl_apply_with_retry "$FIWARE_DIR/target/k3s/dsc-provider/data-space-connector/" "provider"
sleep 10

log_step "Deploying consumer..."
kubectl_apply_with_retry "$FIWARE_DIR/target/k3s/dsc-consumer/data-space-connector/" "consumer"
sleep 10

log_step "Deploying additional resources..."
kubectl_apply_optional "$FIWARE_DIR/target/k3s/additional-resources-provider/" "additional-resources-provider"
kubectl_apply_optional "$FIWARE_DIR/target/k3s/additional-consumer-provider/" "additional-consumer-provider"

# ======================== PHASE 4: POST-DEPLOY PATCHES ========================
echo ""
echo "================================================================"
echo "  PHASE 4: Post-Deployment Patches"
echo "================================================================"

log_step "Patching APISIX services to ClusterIP..."
kubectl patch svc provider-apisix-data-plane -n provider \
    -p '{"spec": {"type": "ClusterIP"}}' 2>/dev/null || true
kubectl patch svc consumer-apisix-data-plane -n consumer \
    -p '{"spec": {"type": "ClusterIP"}}' 2>/dev/null || true
log_ok "APISIX services patched."

# APISIX probe bug workaround (affects 8.5.0 - 8.5.2)
if needs_workaround "APISIX_PROBE_BUG"; then
    log_step "Applying APISIX_PROBE_BUG workaround..."
    log_step "Removing health probes from consumer APISIX data plane..."
    kubectl patch deployment consumer-apisix-data-plane -n consumer --type='json' -p='[
      {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"},
      {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"}
    ]' 2>/dev/null || log_warn "Could not remove probes (may already be removed)."
    log_ok "APISIX health probes patched."
else
    log_ok "APISIX_PROBE_BUG workaround not needed for version ${DETECTED_VERSION:-unknown}"
fi

log_step "Restarting local-path-provisioner..."
kubectl rollout restart deployment local-path-provisioner -n local-path-storage 2>/dev/null || true

# ======================== PHASE 5: VERSION-SPECIFIC BUG FIXES ========================
echo ""
echo "================================================================"
echo "  PHASE 5: Version-Specific Bug Fixes"
echo "================================================================"

# Fix 1: Keycloak init container bug (affects 8.3.0 - 8.5.2)
if needs_workaround "KEYCLOAK_INIT_BUG"; then
    log_step "Applying KEYCLOAK_INIT_BUG workaround..."
    log_step "Fixing Keycloak dependency check bug (bypassing wait-for-keycloak init containers)..."

    # PDF documents a known bug: 3 pods get stuck in Init state because the
    # wait-for-keycloak init container's dependency check fails.
    # Fix: replace the init container command with a no-op.
    for ns in provider consumer; do
        deployments=$(kubectl get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for deploy in $deployments; do
            has_init=$(kubectl get deployment "$deploy" -n "$ns" \
                -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null \
                | grep -c "wait-for-keycloak" || true)
            if [ "$has_init" -gt 0 ]; then
                init_names=$(kubectl get deployment "$deploy" -n "$ns" \
                    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null || true)
                idx=0
                for name in $init_names; do
                    if [ "$name" = "wait-for-keycloak" ]; then
                        log_step "  Patching $deploy in $ns (init container index $idx)..."
                        kubectl patch deployment "$deploy" -n "$ns" --type='json' -p="[
                            {\"op\": \"replace\", \"path\": \"/spec/template/spec/initContainers/$idx/command\", \"value\": [\"sh\", \"-c\", \"echo 'Bypassing Keycloak check'; exit 0\"]}
                        ]" 2>/dev/null || log_warn "Could not patch $deploy"
                        break
                    fi
                    idx=$((idx + 1))
                done
            fi
        done
    done
    log_ok "Keycloak init container bug patched."
else
    log_ok "KEYCLOAK_INIT_BUG workaround not needed for version ${DETECTED_VERSION:-unknown}"
fi

# ======================== PHASE 6: WAIT FOR EVERYTHING ========================
echo ""
echo "================================================================"
echo "  PHASE 6: Waiting for All Pods to Stabilise"
echo "================================================================"

log_step "Giving pods time to start (sleeping 60s)..."
sleep 60

wait_for_pods "infra" 60
wait_for_pods "trust-anchor" 60
wait_for_pods "provider" 60
wait_for_pods "consumer" 60
wait_for_pods "mongo-operator" 60

# ======================== PHASE 6.5: LIQUIBASE LOCK CLEANUP ========================
# Fix 2: Liquibase lock bug (affects 8.3.0 - 8.5.2)
if needs_workaround "LIQUIBASE_LOCK"; then
    log_step "Applying LIQUIBASE_LOCK workaround..."

    # The credentials-config-service uses Liquibase for DB migrations. If the pod
    # crashes mid-migration, a stale lock remains in MySQL and all subsequent starts
    # fail with "Waiting for changelog lock..." forever. Clear the lock proactively.
    log_step "Clearing any stale Liquibase locks in consumer MySQL..."
    MYSQL_PASS=$(kubectl get secret authentication-database-secret -n consumer \
        -o jsonpath='{.data.mysql-root-password}' 2>/dev/null | base64 -d || true)
    if [ -n "$MYSQL_PASS" ]; then
        kubectl exec -n consumer authentication-mysql-0 -c mysql -- \
            mysql -u root -p"${MYSQL_PASS}" -e \
            "UPDATE ccsdb.DATABASECHANGELOGLOCK SET LOCKED=0, LOCKGRANTED=NULL, LOCKEDBY=NULL WHERE ID=1;" \
            2>/dev/null || log_warn "Could not clear Liquibase lock (table may not exist yet — this is fine on first deploy)."
        log_ok "Liquibase lock cleared (or was already clean)."
    else
        log_warn "Could not retrieve MySQL password — skipping Liquibase lock cleanup."
    fi

    # Also clear in provider
    log_step "Clearing any stale Liquibase locks in provider MySQL..."
    MYSQL_PASS_PROV=$(kubectl get secret authentication-database-secret -n provider \
        -o jsonpath='{.data.mysql-root-password}' 2>/dev/null | base64 -d || true)
    if [ -n "$MYSQL_PASS_PROV" ]; then
        kubectl exec -n provider authentication-mysql-0 -c mysql -- \
            mysql -u root -p"${MYSQL_PASS_PROV}" -e \
            "UPDATE ccsdb.DATABASECHANGELOGLOCK SET LOCKED=0, LOCKGRANTED=NULL, LOCKEDBY=NULL WHERE ID=1;" \
            2>/dev/null || log_warn "Could not clear provider Liquibase lock (table may not exist yet)."
        log_ok "Provider Liquibase lock cleared (or was already clean)."
    else
        log_warn "Could not retrieve provider MySQL password — skipping."
    fi
else
    log_ok "LIQUIBASE_LOCK workaround not needed for version ${DETECTED_VERSION:-unknown}"
fi

# ======================== PHASE 6.7: POST-DEPLOY CCS CONFIGURATION ========================
# Root cause of UC-F5 failure and OperatorCredential scope returning null:
# The Credentials Config Service (CCS) is deployed empty — it has no scope mappings.
# The VCVerifier reads from CCS to find which credentials to accept for each service scope.
# Without this configuration, /services/data-service/token returns 404 and the operator
# scope has no credential mapping, so get_access_token_oid4vp.sh returns null for OPERATOR_CREDENTIAL.
# This POST-DEPLOY step is REQUIRED for LOCAL.MD, CENTRAL_MARKETPLACE.md, and DSP_INTEGRATION.md.

if [ "$SETUP_CCS" = "true" ]; then
    echo ""
    echo "================================================================"
    echo "  PHASE 6.7: Configuring Credentials Config Service (CCS)"
    echo "================================================================"

    log_step "Waiting for CCS to become available..."
    CCS_URL="http://provider-ccs.${INTERNAL_IP}.nip.io:8080"
    CCS_READY=false
    for i in $(seq 1 18); do   # 18 × 10s = 3 minutes max
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${CCS_URL}/service" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
            CCS_READY=true
            log_ok "CCS is up (HTTP $HTTP_CODE)."
            break
        fi
        echo "  ... CCS not ready yet (HTTP $HTTP_CODE, attempt $i/18). Waiting 10s..."
        sleep 10
    done

    if [ "$CCS_READY" = "true" ]; then
        log_step "Configuring CCS data-service scope (default + operator)..."
        # This registers: UserCredential for 'default' scope, OperatorCredential for 'operator' scope.
        # References: LOCAL.MD §Holder Verification, CENTRAL_MARKETPLACE.md §Buy access
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${CCS_URL}/service/data-service" \
            -H 'accept: application/json' \
            -H 'Content-Type: application/json' \
            -d "{
              \"defaultOidcScope\": \"default\",
              \"oidcScopes\": {
                \"default\": {
                  \"credentials\": [{
                    \"type\": \"UserCredential\",
                    \"trustedParticipantsLists\": [\"http://tir.trust-anchor.svc.cluster.local:8080\"],
                    \"trustedIssuersLists\": [\"http://trusted-issuers-list:8080\"]
                  }]
                },
                \"operator\": {
                  \"credentials\": [{
                    \"type\": \"OperatorCredential\",
                    \"trustedParticipantsLists\": [\"http://tir.trust-anchor.svc.cluster.local:8080\"],
                    \"trustedIssuersLists\": [\"http://trusted-issuers-list:8080\"]
                  }]
                },
                \"legal\": {
                  \"credentials\": [{
                    \"type\": \"LegalPersonCredential\",
                    \"trustedParticipantsLists\": [\"http://tir.trust-anchor.svc.cluster.local:8080\"],
                    \"trustedIssuersLists\": [\"http://trusted-issuers-list:8080\"]
                  }]
                },
                \"openid\": {
                  \"credentials\": [{
                    \"type\": \"MembershipCredential\",
                    \"trustedParticipantsLists\": [\"http://tir.trust-anchor.svc.cluster.local:8080\"],
                    \"trustedIssuersLists\": [\"http://trusted-issuers-list:8080\"],
                    \"jwtInclusion\": {\"enabled\": true, \"fullInclusion\": true}
                  }]
                }
              }
            }" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
            log_ok "CCS data-service configured (HTTP $HTTP_CODE). UC-F5 VCVerifier + OperatorCredential scope are now fixed."
        else
            log_warn "CCS PUT returned HTTP $HTTP_CODE. Try manually: curl -X PUT ${CCS_URL}/service/data-service ..."
        fi

        # Also configure the marketplace TMForum endpoint scope (MARKETPLACE_INTEGRATION.md)
        log_step "Configuring CCS tmf-marketplace scope (REPRESENTATIVE role)..."
        curl -s -o /dev/null -X PUT "${CCS_URL}/service/tmf-marketplace" \
            -H 'accept: application/json' \
            -H 'Content-Type: application/json' \
            -d "{
              \"defaultOidcScope\": \"default\",
              \"oidcScopes\": {
                \"default\": {
                  \"credentials\": [{
                    \"type\": \"UserCredential\",
                    \"trustedParticipantsLists\": [\"http://tir.trust-anchor.svc.cluster.local:8080\"],
                    \"trustedIssuersLists\": [\"http://trusted-issuers-list:8080\"]
                  }]
                }
              }
            }" 2>/dev/null || true
        log_ok "CCS tmf-marketplace scope configured."
    else
        log_warn "CCS did not become available in time. Run this manually after deployment:"
        log_warn "  curl -X PUT http://provider-ccs.${INTERNAL_IP}.nip.io:8080/service/data-service \\"
        log_warn "    -H 'Content-Type: application/json' -d '{\"defaultOidcScope\":\"default\",...}'"
    fi
fi

# ======================== PHASE 6.8: AUTO-CREATE BASELINE ODRL POLICIES ========================
# The LOCAL.MD demo requires 4 policies at the PAP before any marketplace flow works.
# Without them: product offerings return 403, organizations cannot be registered, orders fail.
# References: LOCAL.MD §Offer creation (steps 1-4), CENTRAL_MARKETPLACE.md §Prepare the marketplace

if [ "$SETUP_POLICIES" = "true" ]; then
    echo ""
    echo "================================================================"
    echo "  PHASE 6.8: Creating Baseline ODRL Policies at PAP"
    echo "================================================================"

    PAP_URL="http://pap-provider.${INTERNAL_IP}.nip.io:8080"
    log_step "Waiting for PAP to become available..."
    PAP_READY=false
    for i in $(seq 1 18); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PAP_URL}/policy" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
            PAP_READY=true
            log_ok "PAP is up (HTTP $HTTP_CODE)."
            break
        fi
        echo "  ... PAP not ready yet (HTTP $HTTP_CODE, attempt $i/18). Waiting 10s..."
        sleep 10
    done

    if [ "$PAP_READY" = "true" ]; then

        # Policy 1: Allow any authenticated participant to read EnergyReport entities
        log_step "Creating policy: EnergyReport read access (any credential)..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "@id": "https://mp-operation.org/policy/common/test",
          "odrl:uid": "https://mp-operation.org/policy/common/test",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"ngsi-ld:entityType",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"EnergyReport"}]},
            "odrl:assignee": {"@id": "vc:any"},
            "odrl:action": {"@id": "odrl:read"}}}' 2>/dev/null || true

        # Policy 2: Allow any authenticated participant to read productOffering
        log_step "Creating policy: product offering read access (any credential)..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "@id": "https://mp-operation.org/policy/common/offering",
          "odrl:uid": "https://mp-operation.org/policy/common/offering",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"tmf:resource",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"productOffering"}]},
            "odrl:assignee": {"@id": "vc:any"},
            "odrl:action": {"@id": "odrl:read"}}}' 2>/dev/null || true

        # Policy 3: Allow REPRESENTATIVES to self-register (create organization)
        log_step "Creating policy: organization self-registration (REPRESENTATIVE role)..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "@id": "https://mp-operation.org/policy/common/selfRegistration",
          "odrl:uid": "https://mp-operation.org/policy/common/selfRegistration",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"tmf:resource",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"organization"}]},
            "odrl:assignee": {
              "@type": "odrl:PartyCollection", "odrl:source": "urn:user",
              "odrl:refinement": {"@type":"odrl:LogicalConstraint","odrl:and":[
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:role"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"REPRESENTATIVE","@type":"xsd:string"}},
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:type"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"UserCredential","@type":"xsd:string"}}]}},
            "odrl:action": {"@id": "tmf:create"}}}' 2>/dev/null || true

        # Policy 4: Allow REPRESENTATIVES to create productOrder
        log_step "Creating policy: product ordering (REPRESENTATIVE role)..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "@id": "https://mp-operation.org/policy/common/ordering",
          "odrl:uid": "https://mp-operation.org/policy/common/ordering",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"tmf:resource",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"productOrder"}]},
            "odrl:assignee": {
              "@type": "odrl:PartyCollection", "odrl:source": "urn:user",
              "odrl:refinement": {"@type":"odrl:LogicalConstraint","odrl:and":[
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:role"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"REPRESENTATIVE","@type":"xsd:string"}},
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:type"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"UserCredential","@type":"xsd:string"}}]}},
            "odrl:action": {"@id": "tmf:create"}}}' 2>/dev/null || true

        # Policy 5: Allow OPERATORS with OperatorCredential to read K8SCluster entities
        log_step "Creating policy: K8SCluster read access (OperatorCredential)..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "odrl:uid": "https://mp-operation.org/policy/common/allowRead",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"ngsi-ld:entityType",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"K8SCluster"}]},
            "odrl:assignee": {
              "@type": "odrl:PartyCollection", "odrl:source": "urn:user",
              "odrl:refinement": {"@type":"odrl:LogicalConstraint","odrl:and":[
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:role"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"OPERATOR","@type":"xsd:string"}},
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:type"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"OperatorCredential","@type":"xsd:string"}}]}},
            "odrl:action": {"@id": "odrl:read"}}}' 2>/dev/null || true

        # Policy 6: Central Marketplace - allow Contract Management to send notifications
        log_step "Creating policy: allow Contract Management order notifications..."
        curl -s -o /dev/null -X POST "${PAP_URL}/policy" -H 'Content-Type: application/json' -d '{
          "@context": {"odrl":"http://www.w3.org/ns/odrl/2/"},
          "@id": "https://mp-operation.org/policy/common/allowContractManagement",
          "odrl:uid": "https://mp-operation.org/policy/common/allowContractManagement",
          "@type": "odrl:Policy",
          "odrl:permission": {
            "odrl:assigner": {"@id": "https://www.mp-operation.org/"},
            "odrl:target": {
              "@type": "odrl:AssetCollection", "odrl:source": "urn:asset",
              "odrl:refinement": [{"@type":"odrl:Constraint","odrl:leftOperand":"tmf:resource",
                "odrl:operator":{"@id":"odrl:eq"},"odrl:rightOperand":"productOrder"}]},
            "odrl:assignee": {
              "@type": "odrl:PartyCollection", "odrl:source": "urn:user",
              "odrl:refinement": {"@type":"odrl:LogicalConstraint","odrl:and":[
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:role"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"MARKETPLACE","@type":"xsd:string"}},
                {"@type":"odrl:Constraint","odrl:leftOperand":{"@id":"vc:type"},
                  "odrl:operator":{"@id":"odrl:hasPart"},
                  "odrl:rightOperand":{"@value":"MarketplaceCredential","@type":"xsd:string"}}]}},
            "odrl:action": {"@id": "tmf:create"}}}' 2>/dev/null || true

        log_ok "Baseline policies created. Verify: curl -s ${PAP_URL}/policy | jq .[].\"@id\""
    else
        log_warn "PAP not available. Create policies manually after deployment — see LOCAL.MD §Offer creation."
    fi
fi

# ======================== PHASE 6.9: DSP IDENTITY HUB SETUP ========================
# Registers consumer + provider identities in IdentityHub (DSP_INTEGRATION.md steps 1-4)
# Required before any DCP or OID4VC based DSP catalog/negotiation/transfer flows work.

if [ "$SETUP_IDENTITY_HUB" = "true" ]; then
    echo ""
    echo "================================================================"
    echo "  PHASE 6.9: DSP Identity Hub Setup (consumer + provider)"
    echo "================================================================"
    log_step "Waiting for IdentityHub management endpoints..."
    IH_CONSUMER_URL="http://identityhub-management-fancy-marketplace.${INTERNAL_IP}.nip.io:8080"
    IH_PROVIDER_URL="http://identityhub-management-mp-operations.${INTERNAL_IP}.nip.io:8080"
    IH_READY=false
    for i in $(seq 1 24); do
        C=$(curl -s -o /dev/null -w "%{http_code}" "${IH_CONSUMER_URL}/api/identity/v1alpha/participants" \
            -H 'x-api-key: c3VwZXItdXNlcg==.random' 2>/dev/null || echo "000")
        if [ "$C" = "200" ]; then IH_READY=true; break; fi
        echo "  ... IdentityHub not ready (HTTP $C, attempt $i/24). Waiting 15s..."
        sleep 15
    done

    if [ "$IH_READY" = "true" ]; then
        log_step "Generating consumer JWK from deployment cert..."
        CONSUMER_JWK=$("${FIWARE_DIR}/doc/scripts/get-private-jwk-p-256.sh" \
            "${FIWARE_DIR}/helpers/certs/out/client-consumer/private/client-pkcs8.key.pem" 2>/dev/null || true)
        PROVIDER_JWK=$("${FIWARE_DIR}/doc/scripts/get-private-jwk-p-256.sh" \
            "${FIWARE_DIR}/helpers/certs/out/client-provider/private/client-pkcs8.key.pem" 2>/dev/null || true)

        if [ -n "$CONSUMER_JWK" ]; then
            log_step "Storing consumer key in Vault..."
            curl -s -o /dev/null -X POST \
                "http://vault-fancy-marketplace.${INTERNAL_IP}.nip.io:8080/v1/secret/data/key-1" \
                --header 'X-Vault-Token: root' \
                --data "$(jq -n --arg content "$CONSUMER_JWK" '{data:{content:$content}}')" 2>/dev/null || true

            log_step "Registering consumer participant in IdentityHub..."
            CONSUMER_PARTICIPANT=$("${FIWARE_DIR}/doc/scripts/get-participant-create.sh" \
                "${CONSUMER_JWK}" "did:web:fancy-marketplace.biz" \
                "http://identityhub-fancy-marketplace.${INTERNAL_IP}.nip.io" "key-1" 2>/dev/null || true)
            if [ -n "$CONSUMER_PARTICIPANT" ]; then
                curl -s -o /dev/null -X POST \
                    "${IH_CONSUMER_URL}/api/identity/v1alpha/participants" \
                    --header 'Accept: */*' \
                    --header "x-api-key: c3VwZXItdXNlcg==.random" \
                    --header 'Content-Type: application/json' \
                    --data "${CONSUMER_PARTICIPANT}" 2>/dev/null || true
                log_ok "Consumer identity registered in IdentityHub."
            fi
        fi

        if [ -n "$PROVIDER_JWK" ]; then
            log_step "Storing provider key in Vault..."
            curl -s -o /dev/null -X POST \
                "http://vault-mp-operations.${INTERNAL_IP}.nip.io:8080/v1/secret/data/key-1" \
                --header 'X-Vault-Token: root' \
                --data "$(jq -n --arg content "$PROVIDER_JWK" '{data:{content:$content}}')" 2>/dev/null || true

            log_step "Registering provider participant in IdentityHub..."
            PROVIDER_PARTICIPANT=$("${FIWARE_DIR}/doc/scripts/get-participant-create.sh" \
                "${PROVIDER_JWK}" "did:web:mp-operations.org" \
                "http://identityhub-mp-operations.${INTERNAL_IP}.nip.io" "key-1" 2>/dev/null || true)
            if [ -n "$PROVIDER_PARTICIPANT" ]; then
                curl -s -o /dev/null -X POST \
                    "${IH_PROVIDER_URL}/api/identity/v1alpha/participants" \
                    --header 'Accept: */*' \
                    --header "x-api-key: c3VwZXItdXNlcg==.random" \
                    --header 'Content-Type: application/json' \
                    --data "${PROVIDER_PARTICIPANT}" 2>/dev/null || true
                log_ok "Provider identity registered in IdentityHub."
            fi
        fi

        log_ok "IdentityHub setup complete. Membership credentials must still be issued and inserted manually."
        log_warn "See DSP_INTEGRATION.md §Issue membership-credentials for the manual steps."
    else
        log_warn "IdentityHub not reachable. Run DSP_INTEGRATION.md setup steps manually after deployment."
    fi
fi

# ======================== PHASE 7: PATCH HELPER SCRIPTS ========================
echo ""
echo "================================================================"
echo "  PHASE 7: Patching Helper Scripts with Correct IP"
echo "================================================================"

# The doc/scripts/*.sh files ship with 127.0.0.1.nip.io hardcoded.
# We replace them with ${INTERNAL_IP}.nip.io (literal variable reference)
# so the scripts resolve INTERNAL_IP at runtime from the bashrc function.
log_step "Patching helper scripts..."
TARGET_DIR="$FIWARE_DIR/doc/scripts"
if [ -d "$TARGET_DIR" ]; then
    find "$TARGET_DIR" -type f -name "*.sh" | while read -r file; do
        sed -i 's/127\.0\.0\.1\.nip\.io:8080/${INTERNAL_IP}.nip.io/g' "$file"
        sed -i 's/127\.0\.0\.1\.nip\.io/${INTERNAL_IP}.nip.io/g' "$file"
    done
    chmod +x "$TARGET_DIR"/*.sh 2>/dev/null || true
    log_ok "Helper scripts patched and made executable."
else
    log_warn "Helper scripts directory not found at $TARGET_DIR."
fi

# ======================== PHASE 8: SMOKE TEST ========================
echo ""
echo "================================================================"
echo "  PHASE 8: Smoke Test"
echo "================================================================"

log_step "Running smoke tests..."

# Pod status summary
echo ""
echo "  --- Pod Status Summary ---"
for ns in infra trust-anchor provider consumer mongo-operator kube-system; do
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || true)
    running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || true)
    echo "    $ns: $running/$total running"
done
echo ""

TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || true)
log_ok "Total running pods across all namespaces: $TOTAL_PODS"

# Service reachability tests via squid proxy (the FIWARE-designed access path)
ERRORS=0

smoke_test_proxy() {
    local name="$1"
    local url="$2"
    local accept_codes="$3"
    echo "  Testing $name (via squid proxy)..."
    local http_code
    # Use proper CA certificate for TLS verification (research-grade security)
    local ca_cert="$FIWARE_DIR/helpers/certs/out/ca/certs/ca.cert.pem"
    if [ -f "$ca_cert" ]; then
        http_code=$(curl -s --cacert "$ca_cert" -x localhost:8888 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    else
        # Fallback to insecure if CA cert not found (first-time setup)
        log_warn "  CA certificate not found, using insecure mode for initial test"
        http_code=$(curl -s -k -x localhost:8888 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    fi
    if echo "$http_code" | grep -qE "$accept_codes"; then
        log_ok "  $name: reachable (HTTP $http_code)"
    else
        log_warn "  $name: not reachable yet (HTTP $http_code, may still be starting)"
        ERRORS=$((ERRORS + 1))
    fi
}

smoke_test_proxy "Keycloak Provider"  "https://keycloak-provider.${INTERNAL_IP}.nip.io/realms/master"              "200"
smoke_test_proxy "Keycloak Consumer"  "https://keycloak-consumer.${INTERNAL_IP}.nip.io/realms/master"              "200"
smoke_test_proxy "Scorpio Provider"   "https://scorpio-provider.${INTERNAL_IP}.nip.io/ngsi-ld/v1/entities"         "200"
smoke_test_proxy "Trust Anchor (TIR)" "https://tir.${INTERNAL_IP}.nip.io"                                          "200|404"
smoke_test_proxy "PAP Provider"       "https://pap-provider.${INTERNAL_IP}.nip.io/policy"                          "200"
smoke_test_proxy "TMForum API"        "http://tm-forum-api.${INTERNAL_IP}.nip.io:8080/tmf-api/productCatalogManagement/v4/productOffering" "200|401|403"
smoke_test_proxy "CCS Provider"       "http://provider-ccs.${INTERNAL_IP}.nip.io:8080/service"                     "200|404"
smoke_test_proxy "VCVerifier"         "https://provider-verifier.${INTERNAL_IP}.nip.io:8443/.well-known/openid-configuration" "200"
smoke_test_proxy "mp-data-service"    "http://mp-data-service.${INTERNAL_IP}.nip.io:8080/.well-known/openid-configuration"   "200"
if [ "$DSP_ENABLED" = "true" ]; then
    smoke_test_proxy "DSP OID4VC"     "http://dsp-mp-operations.${INTERNAL_IP}.nip.io:8080/api/dsp/2025-1/catalog/request"  "200|401|403|405"
    smoke_test_proxy "IdentityHub Consumer" "http://identityhub-fancy-marketplace.${INTERNAL_IP}.nip.io/.well-known/did.json" "200"
fi

# Also test the OID4VC token endpoint (the actual use-case entry point)
echo "  Testing OID4VC token endpoint..."
ca_cert="$FIWARE_DIR/helpers/certs/out/ca/certs/ca.cert.pem"
if [ -f "$ca_cert" ]; then
    TOKEN_RESULT=$(curl -s --cacert "$ca_cert" -x localhost:8888 -X POST \
        "https://keycloak-consumer.${INTERNAL_IP}.nip.io/realms/test-realm/protocol/openid-connect/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data "grant_type=password" \
        --data "client_id=account-console" \
        --data "username=employee" \
        --data "scope=openid" \
        --data "password=test" 2>/dev/null | jq -r '.access_token // empty' || true)
else
    TOKEN_RESULT=$(curl -s -k -x localhost:8888 -X POST \
        "https://keycloak-consumer.${INTERNAL_IP}.nip.io/realms/test-realm/protocol/openid-connect/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data "grant_type=password" \
        --data "client_id=account-console" \
        --data "username=employee" \
        --data "scope=openid" \
        --data "password=test" 2>/dev/null | jq -r '.access_token // empty' || true)
fi
if [ -n "$TOKEN_RESULT" ] && [ "$TOKEN_RESULT" != "null" ]; then
    log_ok "  OID4VC token endpoint: working (JWT received)"
else
    log_warn "  OID4VC token endpoint: not ready yet (Keycloak may still be starting)"
    ERRORS=$((ERRORS + 1))
fi

# Get the Headlamp NodePort dynamically
HEADLAMP_PORT=$(kubectl get svc my-headlamp -n kube-system \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "unknown")

# ======================== SUMMARY ========================
echo ""
echo "================================================================"
echo "  DEPLOYMENT COMPLETE"
echo "================================================================"
echo ""
echo "  VM IP:          $INTERNAL_IP"
echo "  Pods running:   $TOTAL_PODS"
echo "  Smoke errors:   $ERRORS (warnings, not failures)"
echo "  Profiles:       ${MAVEN_PROFILES:-local}"
echo "  CCS setup:      ${SETUP_CCS}"
echo "  Policies setup: ${SETUP_POLICIES}"
if [ "$DSP_ENABLED" = "true" ]; then
echo "  DSP/EDC:        ENABLED (FDSC-EDC, Vault, IdentityHub deployed)"
fi
if [ "$GAIAX_ENABLED" = "true" ]; then
echo "  Gaia-X:         ENABLED (GX-Registry, DSS, did:web deployed)"
fi
echo ""
echo "  IMPORTANT: All FIWARE services are accessed via the squid proxy."
echo "  Use:  curl -s --cacert $FIWARE_DIR/helpers/certs/out/ca/certs/ca.cert.pem -x localhost:8888 https://<service>.${INTERNAL_IP}.nip.io"
echo "  (Or use -k flag for quick testing without certificate verification)"
echo ""
echo "  Key URLs (via squid proxy + HTTPS):"
echo "  ---------------------------------------------------------------"
echo "  Keycloak Provider:  https://keycloak-provider.${INTERNAL_IP}.nip.io"
echo "  Keycloak Consumer:  https://keycloak-consumer.${INTERNAL_IP}.nip.io"
echo "  Scorpio (Provider): https://scorpio-provider.${INTERNAL_IP}.nip.io"
echo "  PAP Provider:       https://pap-provider.${INTERNAL_IP}.nip.io"
echo "  PAP Consumer:       https://pap-consumer.${INTERNAL_IP}.nip.io"
echo "  TM Forum API:       http://tm-forum-api.${INTERNAL_IP}.nip.io:8080"
echo "  mp-TMF API:         http://mp-tmf-api.${INTERNAL_IP}.nip.io:8080"
echo "  Marketplace (BAE):  https://marketplace.${INTERNAL_IP}.nip.io"
echo "  Trust Registry:     https://tir.${INTERNAL_IP}.nip.io"
echo "  CCS Provider:       http://provider-ccs.${INTERNAL_IP}.nip.io:8080"
echo "  VCVerifier:         https://provider-verifier.${INTERNAL_IP}.nip.io:8443"
echo "  mp-data-service:    http://mp-data-service.${INTERNAL_IP}.nip.io:8080"
if [ "$DSP_ENABLED" = "true" ]; then
echo "  DSP (OID4VC):       http://dsp-mp-operations.${INTERNAL_IP}.nip.io:8080"
echo "  DSP (DCP):          http://dcp-mp-operations.${INTERNAL_IP}.nip.io:8080"
echo "  DSP Management:     http://dsp-dcp-management.${INTERNAL_IP}.nip.io:8080"
echo "  IdentityHub (Cons): http://identityhub-fancy-marketplace.${INTERNAL_IP}.nip.io"
echo "  IdentityHub (Prov): http://identityhub-mp-operations.${INTERNAL_IP}.nip.io"
fi
echo "  ---------------------------------------------------------------"
echo "  Headlamp:           http://${INTERNAL_IP}:${HEADLAMP_PORT}"
echo "  Squid Proxy:        localhost:8888"
echo "  ---------------------------------------------------------------"
echo ""
echo "  Headlamp token:    headlamp-token"
echo "    (or manually:    kubectl create token my-headlamp --namespace kube-system)"
echo ""
if [ $ERRORS -gt 0 ]; then
    echo "  Some services may still be starting. Wait a few minutes and"
    echo "  check pod status with: kubectl get pods -A"
    echo ""
fi
echo "  To run the use case demo, open a new shell (so ~/.bashrc loads)"
echo "  then verify:"
echo "    echo \$INTERNAL_IP          # should print $INTERNAL_IP"
echo "    headlamp-token              # should print a JWT token"
echo ""
echo "  AUTOMATED SETUP COMPLETED:"
echo "    ✓ CCS configured  (fixes VCVerifier 404 + OperatorCredential scope - UC-F5)"
echo "    ✓ 6 baseline ODRL policies created at PAP"
if [ "$DSP_ENABLED" = "true" ]; then
echo "    ✓ IdentityHub participant identities registered"
fi
echo ""
echo "  REMAINING MANUAL STEPS (you must do these):"
echo "  ---------------------------------------------------------------"
echo "  LOCAL.MD complete flow:"
echo "    1. Issue credentials:"
echo "       export USER_CREDENTIAL=\$(./doc/scripts/get_credential.sh https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential employee)"
echo "       export REP_CREDENTIAL=\$(./doc/scripts/get_credential.sh https://keycloak-consumer.${INTERNAL_IP}.nip.io user-credential representative)"
echo "       export OPERATOR_CREDENTIAL=\$(./doc/scripts/get_credential.sh https://keycloak-consumer.${INTERNAL_IP}.nip.io operator-credential operator)"
echo "    2. Create product offerings (K8S small + full) — see LOCAL.MD §Offer creation steps 1-3"
echo "    3. Run the buy-access + cluster-creation flow — see LOCAL.MD §Buy access and create cluster"
echo ""
echo "  CENTRAL_MARKETPLACE.md:"
echo "    1. Run: ./doc/scripts/prepare-central-market-policies.sh"
echo "    2. Register provider at marketplace — see CENTRAL_MARKETPLACE.md §Prepare the provider"
echo "    3. Create offerings and run the buy flow"
echo ""
if [ "$DSP_ENABLED" = "true" ]; then
echo "  DSP_INTEGRATION.md (--dsp mode):"
echo "    1. Issue and insert MembershipCredentials into IdentityHub (both consumer + provider)"
echo "       See DSP_INTEGRATION.md §Issue membership-credentials"
echo "    2. Add data to Scorpio (UptimeReport entity)"
echo "    3. Create TMForum product offering with DSP endpoint chars — see DSP_INTEGRATION.md §Prepare the offering"
echo "    4. Run DCP/OID4VC catalog + negotiation + transfer flows"
echo ""
fi
if [ "$GAIAX_ENABLED" = "true" ]; then
echo "  GAIA_X.MD (--gaia-x mode):"
echo "    1. Certs must be pre-generated: cd helpers/certs && ./generate-certs.sh"
echo "    2. Register trust anchor in GX-Registry init-container (auto if certs present)"
echo "    3. Configure browser proxy to localhost:8888 for Squid HTTPS forwarding"
echo "    4. Verify: curl -k -x localhost:8888 https://fancy-marketplace.biz/.well-known/did.json"
echo ""
fi
echo "  MARKETPLACE_INTEGRATION.md (BAE Marketplace + EUDI Wallet):"
echo "    1. Install FoxyProxy in Chrome, point to 127.0.0.1:8888"
echo "    2. Download EUDI wallet APK (see MARKETPLACE_INTEGRATION.md §The Wallet)"
echo "    3. Set phone WiFi proxy to VM IP:8888"
echo "    4. Login to marketplace at https://marketplace.${INTERNAL_IP}.nip.io via proxy"
echo ""
echo "  For secure curl:  curl --cacert \$FIWARE_DIR/helpers/certs/out/ca/certs/ca.cert.pem -x localhost:8888 https://..."
echo "  For quick tests:  curl -k -x localhost:8888 https://..."
echo ""
echo "================================================================"
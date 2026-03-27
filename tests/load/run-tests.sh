#!/bin/bash
# ============================================================================
# FIWARE Load Testing Runner Script
# ============================================================================
# Runs K6 load tests against the FIWARE deployment.
#
# Prerequisites:
#   - K6 installed (https://k6.io/docs/getting-started/installation/)
#   - FIWARE deployment running
#
# Usage:
#   ./run-tests.sh [smoke|load|stress|soak]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for K6
check_k6() {
    if ! command -v k6 &>/dev/null; then
        log_err "K6 is not installed."
        echo ""
        echo "Install K6:"
        echo "  Ubuntu/Debian: sudo apt install k6"
        echo "  macOS: brew install k6"
        echo "  Docker: docker pull grafana/k6"
        echo ""
        echo "See: https://k6.io/docs/getting-started/installation/"
        exit 1
    fi
    log_ok "K6 found: $(k6 version)"
}

# Detect IP address
get_internal_ip() {
    if [ -n "${INTERNAL_IP:-}" ]; then
        echo "$INTERNAL_IP"
    else
        hostname -I | awk '{print $1}'
    fi
}

# Main
SCENARIO="${1:-smoke}"
INTERNAL_IP=$(get_internal_ip)
DOMAIN="${INTERNAL_IP}.nip.io"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "============================================================================"
echo "  FIWARE Load Testing"
echo "============================================================================"
echo "  Scenario:  $SCENARIO"
echo "  Domain:    $DOMAIN"
echo "  Timestamp: $TIMESTAMP"
echo "============================================================================"
echo ""

check_k6

# Create results directory
mkdir -p "$RESULTS_DIR"

# Verify services are accessible
log_step "Verifying FIWARE services are accessible..."
if curl -s -k --connect-timeout 5 "https://keycloak-provider.${DOMAIN}/health/ready" >/dev/null 2>&1; then
    log_ok "Keycloak Provider is accessible"
else
    log_warn "Keycloak Provider may not be accessible - tests may fail"
fi

# Run K6 tests
log_step "Running K6 ${SCENARIO} test..."

RESULTS_FILE="${RESULTS_DIR}/${SCENARIO}_${TIMESTAMP}"

k6 run \
    --env DOMAIN="$DOMAIN" \
    --env SCENARIO="$SCENARIO" \
    --out json="${RESULTS_FILE}.json" \
    "${SCRIPT_DIR}/k6-fiware-test.js" 2>&1 | tee "${RESULTS_FILE}.log"

# Check results
if [ -f "${RESULTS_FILE}.json" ]; then
    log_ok "Test results saved to ${RESULTS_FILE}.json"
fi

if [ -f "summary.json" ]; then
    mv "summary.json" "${RESULTS_FILE}_summary.json"
    log_ok "Summary saved to ${RESULTS_FILE}_summary.json"
fi

echo ""
echo "============================================================================"
echo "  Test Complete"
echo "============================================================================"
echo "  Results: ${RESULTS_DIR}"
echo "============================================================================"

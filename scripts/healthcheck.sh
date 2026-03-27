#!/bin/bash
# ============================================================================
# FIWARE Data Space Connector - Comprehensive Health Check Script
# ============================================================================
# This script performs a thorough health check of all FIWARE components.
# Run after deployment to verify all services are operational.
#
# Usage:
#   ./healthcheck.sh [--verbose] [--json]
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
FIWARE_DIR="${FIWARE_DIR:-/fiware/data-space-connector}"
INTERNAL_IP="${INTERNAL_IP:-$(hostname -I | awk '{print $1}')}"
CA_CERT="$FIWARE_DIR/helpers/certs/out/ca/certs/ca.cert.pem"
PROXY="localhost:8888"
VERBOSE=false
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json|-j)
            JSON_OUTPUT=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Results tracking
declare -A RESULTS
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

log_check() {
    local name="$1"
    local status="$2"
    local message="$3"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    RESULTS["$name"]="$status:$message"

    if [ "$JSON_OUTPUT" = true ]; then
        return
    fi

    case $status in
        PASS)
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            echo -e "${GREEN}[PASS]${NC} $name: $message"
            ;;
        FAIL)
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            echo -e "${RED}[FAIL]${NC} $name: $message"
            ;;
        WARN)
            WARNINGS=$((WARNINGS + 1))
            echo -e "${YELLOW}[WARN]${NC} $name: $message"
            ;;
    esac
}

check_service_http() {
    local name="$1"
    local url="$2"
    local expected_codes="$3"

    local http_code
    if [ -f "$CA_CERT" ]; then
        http_code=$(curl -s --cacert "$CA_CERT" -x "$PROXY" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    else
        http_code=$(curl -s -k -x "$PROXY" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    fi

    if echo "$http_code" | grep -qE "$expected_codes"; then
        log_check "$name" "PASS" "HTTP $http_code"
    else
        log_check "$name" "FAIL" "HTTP $http_code (expected $expected_codes)"
    fi
}

check_pod_status() {
    local namespace="$1"
    local total
    local running

    total=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
    running=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | \
        awk '($3 == "Running" && $2 ~ /^([0-9]+)\/\1$/) || $3 == "Completed" {count++} END {print count+0}' || echo "0")

    if [ "$total" -eq 0 ]; then
        log_check "Pods ($namespace)" "WARN" "No pods found"
    elif [ "$running" -ge "$total" ]; then
        log_check "Pods ($namespace)" "PASS" "$running/$total running"
    else
        local not_ready=$((total - running))
        log_check "Pods ($namespace)" "FAIL" "$running/$total running ($not_ready not ready)"
    fi
}

check_pvc_status() {
    local namespace="$1"
    local total
    local bound

    total=$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
    bound=$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | grep -c "Bound" || echo "0")

    if [ "$total" -eq 0 ]; then
        if [ "$VERBOSE" = true ]; then
            log_check "PVC ($namespace)" "PASS" "No PVCs (stateless)"
        fi
    elif [ "$bound" -ge "$total" ]; then
        log_check "PVC ($namespace)" "PASS" "$bound/$total bound"
    else
        log_check "PVC ($namespace)" "FAIL" "$bound/$total bound"
    fi
}

check_secret_exists() {
    local namespace="$1"
    local secret_name="$2"

    if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        log_check "Secret $secret_name ($namespace)" "PASS" "exists"
    else
        log_check "Secret $secret_name ($namespace)" "FAIL" "not found"
    fi
}

check_certificate_validity() {
    if [ ! -f "$CA_CERT" ]; then
        log_check "CA Certificate" "FAIL" "not found at $CA_CERT"
        return
    fi

    local expiry
    expiry=$(openssl x509 -enddate -noout -in "$CA_CERT" 2>/dev/null | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -lt 0 ]; then
        log_check "CA Certificate" "FAIL" "expired $((days_left * -1)) days ago"
    elif [ "$days_left" -lt 30 ]; then
        log_check "CA Certificate" "WARN" "expires in $days_left days"
    else
        log_check "CA Certificate" "PASS" "valid for $days_left days"
    fi
}

check_database_connectivity() {
    local namespace="$1"
    local db_type="$2"

    case $db_type in
        postgres)
            local pod
            pod=$(kubectl get pods -n "$namespace" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$pod" ]; then
                if kubectl exec -n "$namespace" "$pod" -- pg_isready -U postgres &>/dev/null; then
                    log_check "PostgreSQL ($namespace)" "PASS" "accepting connections"
                else
                    log_check "PostgreSQL ($namespace)" "FAIL" "not accepting connections"
                fi
            fi
            ;;
        mysql)
            local pod
            pod=$(kubectl get pods -n "$namespace" -l app=mysql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$pod" ]; then
                if kubectl exec -n "$namespace" "$pod" -c mysql -- mysqladmin ping &>/dev/null; then
                    log_check "MySQL ($namespace)" "PASS" "accepting connections"
                else
                    log_check "MySQL ($namespace)" "FAIL" "not accepting connections"
                fi
            fi
            ;;
    esac
}

output_json() {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"internal_ip\": \"$INTERNAL_IP\","
    echo "  \"summary\": {"
    echo "    \"total\": $TOTAL_CHECKS,"
    echo "    \"passed\": $PASSED_CHECKS,"
    echo "    \"failed\": $FAILED_CHECKS,"
    echo "    \"warnings\": $WARNINGS"
    echo "  },"
    echo "  \"checks\": {"
    local first=true
    for key in "${!RESULTS[@]}"; do
        IFS=':' read -r status message <<< "${RESULTS[$key]}"
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo -n "    \"$key\": {\"status\": \"$status\", \"message\": \"$message\"}"
    done
    echo ""
    echo "  }"
    echo "}"
}

# ============================================================================
# Main Health Check
# ============================================================================

if [ "$JSON_OUTPUT" = false ]; then
    echo "============================================================================"
    echo "  FIWARE Data Space Connector - Health Check"
    echo "============================================================================"
    echo "  Timestamp:   $(date)"
    echo "  Internal IP: $INTERNAL_IP"
    echo "  CA Cert:     $CA_CERT"
    echo "============================================================================"
    echo ""
fi

# Section 1: Kubernetes Infrastructure
if [ "$JSON_OUTPUT" = false ]; then
    echo -e "${BLUE}=== Kubernetes Infrastructure ===${NC}"
fi

check_pod_status "kube-system"
check_pod_status "infra"
check_pod_status "trust-anchor"
check_pod_status "provider"
check_pod_status "consumer"
check_pod_status "mongo-operator"

# Section 2: Persistent Volumes
if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo -e "${BLUE}=== Persistent Volumes ===${NC}"
fi

check_pvc_status "provider"
check_pvc_status "consumer"
check_pvc_status "trust-anchor"

# Section 3: Critical Secrets
if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo -e "${BLUE}=== Critical Secrets ===${NC}"
fi

check_secret_exists "infra" "local-wildcard"
check_certificate_validity

# Section 4: Database Connectivity
if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo -e "${BLUE}=== Database Connectivity ===${NC}"
fi

check_database_connectivity "provider" "mysql"
check_database_connectivity "consumer" "mysql"
check_database_connectivity "trust-anchor" "mysql"

# Section 5: Service Endpoints
if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo -e "${BLUE}=== Service Endpoints ===${NC}"
fi

check_service_http "Keycloak Provider" "https://keycloak-provider.${INTERNAL_IP}.nip.io/health/ready" "200"
check_service_http "Keycloak Consumer" "https://keycloak-consumer.${INTERNAL_IP}.nip.io/health/ready" "200"
check_service_http "Scorpio Provider" "https://scorpio-provider.${INTERNAL_IP}.nip.io/q/health" "200"
check_service_http "Trust Registry (TIR)" "https://tir.${INTERNAL_IP}.nip.io" "200|404"
check_service_http "PAP Provider" "https://pap-provider.${INTERNAL_IP}.nip.io/policy" "200"
check_service_http "PAP Consumer" "https://pap-consumer.${INTERNAL_IP}.nip.io/policy" "200"

# Section 6: Proxy Functionality
if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo -e "${BLUE}=== Proxy Functionality ===${NC}"
fi

if curl -s -x "$PROXY" -o /dev/null -w "%{http_code}" "http://example.com" 2>/dev/null | grep -q "200"; then
    log_check "Squid Proxy" "PASS" "forwarding requests"
else
    log_check "Squid Proxy" "FAIL" "not forwarding requests"
fi

# Output results
if [ "$JSON_OUTPUT" = true ]; then
    output_json
else
    echo ""
    echo "============================================================================"
    echo "  Summary"
    echo "============================================================================"
    echo -e "  Total Checks:  $TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed:${NC}        $PASSED_CHECKS"
    echo -e "  ${RED}Failed:${NC}        $FAILED_CHECKS"
    echo -e "  ${YELLOW}Warnings:${NC}      $WARNINGS"
    echo ""

    if [ $FAILED_CHECKS -eq 0 ]; then
        echo -e "${GREEN}All critical checks passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some checks failed. See TROUBLESHOOTING.md for help.${NC}"
        exit 1
    fi
fi

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Grafana 13 Dashboard Exporter (V2 API)
# =============================================================================

# Determine script directory and load .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# Configuration (override via .env, environment variables, or command-line arguments)
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/exported-dashboards}"
CURL_OPTS="${CURL_OPTS:--s --fail --show-error}"

# DASHBOARDS should be defined in .env as:
#   declare -A DASHBOARDS=(
#       ["ad5ks8d"]="today-mobile.json"
#       ["adddvtj"]="today-details.json"
#       ["adsmz7v"]="today.json"
#       ["adz6thx"]="month.json"
#   )
if ! declare -p DASHBOARDS &>/dev/null; then
    error "DASHBOARDS not defined. Please define it in your .env file."
    exit 1
fi


# =============================================================================
# Functions
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export Grafana 13 dashboards using the V2 API.

Options:
    -u, --url URL          Grafana server URL (default: ${GRAFANA_URL})
    -U, --user USER        Grafana username (default: ${GRAFANA_USER})
    -p, --password PASS    Grafana password (default: ****)
    -n, --namespace NS     Grafana namespace (default: ${GRAFANA_NAMESPACE})
    -o, --output DIR       Output directory (default: ${OUTPUT_DIR})
    -e, --env FILE         Path to .env file (default: ${ENV_FILE})
    -h, --help             Show this help message

Environment variables:
    GRAFANA_URL, GRAFANA_USER, GRAFANA_PASSWORD, GRAFANA_NAMESPACE, OUTPUT_DIR, ENV_FILE

Configuration file:
    Copy .env.example to .env in the same directory as this script and edit values.

EOF
    exit 0
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

export_dashboard() {
    local uid="$1"
    local filename="$2"
    local api_url="${GRAFANA_URL}/apis/dashboard.grafana.app/v2/namespaces/${GRAFANA_NAMESPACE}/dashboards/${uid}"
    local output_file="${OUTPUT_DIR}/${filename}"

    log "Exporting dashboard '${uid}' -> ${output_file}"

    local http_response
    if http_response=$(curl ${CURL_OPTS} \
        -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "${api_url}"); then
        echo "${http_response}" | jq '.' > "${output_file}"
        log "  Successfully exported: ${filename}"
    else
        error "  Failed to export dashboard '${uid}' (HTTP error)"
        return 1
    fi
}

# =============================================================================
# Parse command-line arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)       GRAFANA_URL="$2"; shift 2 ;;
        -U|--user)      GRAFANA_USER="$2"; shift 2 ;;
        -p|--password)  GRAFANA_PASSWORD="$2"; shift 2 ;;
        -n|--namespace) GRAFANA_NAMESPACE="$2"; shift 2 ;;
        -o|--output)    OUTPUT_DIR="$2"; shift 2 ;;
        -e|--env)       ENV_FILE="$2"; source "${ENV_FILE}"; shift 2 ;;
        -h|--help)      usage ;;
        *)              error "Unknown option: $1"; usage ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

# Check dependencies
for cmd in curl jq; do
    if ! command -v "${cmd}" &>/dev/null; then
        error "Required command '${cmd}' not found. Please install it."
        exit 1
    fi
done

# Create output directory
mkdir -p "${OUTPUT_DIR}"

log "Grafana URL: ${GRAFANA_URL}"
log "Namespace:   ${GRAFANA_NAMESPACE}"
log "Output dir:  ${OUTPUT_DIR}"
log "Dashboards:  ${#DASHBOARDS[@]}"
echo ""

# Export each dashboard
failed=0
for uid in "${!DASHBOARDS[@]}"; do
    if ! export_dashboard "${uid}" "${DASHBOARDS[${uid}]}"; then
        ((failed++))
    fi
done

echo ""
log "Export complete. Success: $(( ${#DASHBOARDS[@]} - failed )), Failed: ${failed}"

exit "${failed}"
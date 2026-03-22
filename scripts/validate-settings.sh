#!/usr/bin/env bash
#
# Validate settings.yaml before provisioning
# Uses simple text parsing — no yq or python yaml module required

set -euo pipefail

SETTINGS="settings.yaml"
ERRORS=0

err() {
    echo "[ERROR] $*" >&2
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo "[WARN]  $*" >&2
}

if [ ! -f "$SETTINGS" ]; then
    echo "[ERROR] $SETTINGS not found" >&2
    exit 1
fi

# Simple YAML value extractor (works for scalar values in flat/nested keys)
# Usage: get "key" — searches for "key:" and returns the value
get() {
    local result
    result=$(grep -E "^\s*${1}:" "$SETTINGS" 2>/dev/null | head -1 | sed "s/^[^:]*:[[:space:]]*//" | xargs) || true
    echo "$result"
}

# ----------------------------
# Required fields
# ----------------------------
required_keys=(
    "box"
    "kubernetes"
    "crio"
    "calico"
    "control_ip"
    "pod_cidr"
    "service_cidr"
    "worker_ip_prefix"
    "count"
)

for key in "${required_keys[@]}"; do
    val=$(get "$key")
    if [ -z "$val" ]; then
        err "Missing required field: $key"
    fi
done

# ----------------------------
# Validate IP format
# ----------------------------
valid_ip() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

control_ip=$(get "control_ip")
if [ -n "$control_ip" ] && ! valid_ip "$control_ip"; then
    err "Invalid control_ip: $control_ip"
fi

# ----------------------------
# Validate CIDR format
# ----------------------------
valid_cidr() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]
}

pod_cidr=$(get "pod_cidr")
if [ -n "$pod_cidr" ] && ! valid_cidr "$pod_cidr"; then
    err "Invalid pod_cidr: $pod_cidr"
fi

service_cidr=$(get "service_cidr")
if [ -n "$service_cidr" ] && ! valid_cidr "$service_cidr"; then
    err "Invalid service_cidr: $service_cidr"
fi

# ----------------------------
# Validate numeric resource fields
# ----------------------------
is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# CPU values (grep returns all "cpu:" lines — control and workers)
while IFS= read -r cpu_val; do
    cpu_val=$(echo "$cpu_val" | xargs)
    if [ -n "$cpu_val" ] && ! is_positive_int "$cpu_val"; then
        err "cpu must be a positive integer, got: $cpu_val"
    fi
done < <(grep -E '^\s+cpu:' "$SETTINGS" | sed 's/^[^:]*:\s*//' || true)

# Memory values
while IFS= read -r mem_val; do
    mem_val=$(echo "$mem_val" | xargs)
    if [ -n "$mem_val" ] && ! is_positive_int "$mem_val"; then
        err "memory must be a positive integer, got: $mem_val"
    fi
done < <(grep -E '^\s+memory:' "$SETTINGS" | sed 's/^[^:]*:\s*//' || true)

# Worker count
worker_count=$(get "count")
if [ -n "$worker_count" ] && ! [[ "$worker_count" =~ ^[0-9]+$ ]]; then
    err "workers.count must be a non-negative integer, got: $worker_count"
fi

# ----------------------------
# Minimum resource warnings
# ----------------------------
# First cpu: line is control plane
ctrl_cpu=$(grep -E '^\s+cpu:' "$SETTINGS" | head -1 | sed 's/^[^:]*:\s*//' | xargs || true)
ctrl_mem=$(grep -E '^\s+memory:' "$SETTINGS" | head -1 | sed 's/^[^:]*:\s*//' | xargs || true)

if [ -n "$ctrl_cpu" ] && [ "$ctrl_cpu" -lt 2 ] 2>/dev/null; then
    warn "Control plane has $ctrl_cpu CPUs — kubeadm requires at least 2"
fi
if [ -n "$ctrl_mem" ] && [ "$ctrl_mem" -lt 2048 ] 2>/dev/null; then
    warn "Control plane has ${ctrl_mem}MB RAM — recommend at least 2048MB"
fi

# ----------------------------
# Validate provisioning scripts exist
# ----------------------------
for script in scripts/common.sh scripts/control.sh scripts/node.sh; do
    if [ ! -f "$script" ]; then
        err "Provisioning script not found: $script"
    fi
done

# ----------------------------
# Result
# ----------------------------
if [ "$ERRORS" -gt 0 ]; then
    echo "[FAIL] $ERRORS validation error(s) found" >&2
    exit 1
fi

echo "[OK] settings.yaml validated successfully"

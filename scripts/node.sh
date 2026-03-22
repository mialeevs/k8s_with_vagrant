#!/usr/bin/env bash

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

readonly CONFIG_PATH="/vagrant/configs"
readonly SETUP_LOG="/var/log/k8s-worker-setup.log"
readonly MAX_RETRIES=5
readonly RETRY_DELAY=10
readonly TEMP_DIR=$(mktemp -d)

trap 'rm -rf "${TEMP_DIR}"' EXIT

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${SETUP_LOG}"
}

cleanup_on_failure() {
    log "ERROR" "Failed on line ${1:-unknown}"
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    iptables -F || true
    iptables -t nat -F || true
}
trap 'cleanup_on_failure $LINENO' ERR

verify_environment() {
    if [ ! -f "${CONFIG_PATH}/join.sh" ]; then
        log "ERROR" "Join script not found at ${CONFIG_PATH}/join.sh"
        exit 1
    fi

    if ! systemctl is-active --quiet crio; then
        log "ERROR" "CRI-O is not running"
        exit 1
    fi
}

configure_sysctl() {
    log "INFO" "Applying Kubernetes sysctl settings..."

    cat <<EOF | tee /etc/sysctl.d/99-kubernetes-worker.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
vm.max_map_count = 262144
EOF

    sysctl --system
}

join_cluster() {
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        log "INFO" "Node already joined to cluster — skipping"
        return
    fi

    log "INFO" "Joining Kubernetes cluster..."

    chmod 755 "${CONFIG_PATH}/join.sh"

    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if bash "${CONFIG_PATH}/join.sh"; then
            log "INFO" "Successfully joined cluster"
            return
        fi

        log "WARN" "Join attempt $attempt failed. Retrying..."
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done

    log "ERROR" "Failed to join cluster after $MAX_RETRIES attempts"
    exit 1
}

install_node_exporter() {
    log "INFO" "Installing Node Exporter..."

    local VERSION="1.8.2"

    curl -4 -fsSL \
      "https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz" \
      -o "${TEMP_DIR}/node_exporter.tar.gz"

    tar xf "${TEMP_DIR}/node_exporter.tar.gz" -C "${TEMP_DIR}"

    install -m 755 \
      "${TEMP_DIR}/node_exporter-${VERSION}.linux-amd64/node_exporter" \
      /usr/local/bin/node_exporter

    id node_exporter &>/dev/null || useradd -rs /bin/false node_exporter

    cat <<EOF | tee /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now node_exporter
}

main() {
    log "INFO" "Starting worker setup..."

    verify_environment
    configure_sysctl
    join_cluster
    install_node_exporter

    log "INFO" "Worker node setup completed successfully"
    chmod 644 "${SETUP_LOG}"
}

main "$@"

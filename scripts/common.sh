#!/usr/bin/env bash

set -euxo pipefail

SETUP_LOG=${SETUP_LOG:-"/var/log/k8s-setup.log"}
trap 'echo "[ERROR] $(date "+%Y-%m-%d %H:%M:%S") - Script failed on line $LINENO" | tee -a "$SETUP_LOG"' ERR

log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$SETUP_LOG"
}

# ----------------------------
# Validate required variables
# ----------------------------
required_vars=("DNS_SERVERS" "KUBERNETES_VERSION" "CRIO_VERSION")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        log "ERROR" "$var is not set"
        exit 1
    fi
done

# ----------------------------
# Disable swap
# ----------------------------
disable_swap() {
    log "INFO" "Disabling swap..."
    swapoff -a || true
    sed -i '/ swap / s/^/#/' /etc/fstab
}

# ----------------------------
# Configure DNS (Ubuntu 24.04)
# ----------------------------
configure_dns() {
    log "INFO" "Configuring DNS..."

    mkdir -p /etc/systemd/resolved.conf.d/

    cat <<EOF | tee /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=${DNS_SERVERS}
FallbackDNS=8.8.8.8 1.1.1.1
EOF

    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

    log "INFO" "DNS configuration complete"
    getent hosts pkgs.k8s.io || log "WARN" "DNS resolution failed for pkgs.k8s.io"
}

# ----------------------------
# Kernel modules + sysctl
# ----------------------------
container_runtime_setup() {
    log "INFO" "Configuring kernel modules and sysctl..."

    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay || true
    modprobe br_netfilter || true

    cat <<EOF | tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

    sysctl --system
}

# ----------------------------
# Install CRI-O
# ----------------------------
install_crio() {
    log "INFO" "Installing CRI-O ${CRIO_VERSION}..."

    apt-get update
    apt-get install -y curl gpg ca-certificates apt-transport-https

    mkdir -p -m 755 /etc/apt/keyrings

    curl -fsSL \
        "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    chmod 644 /etc/apt/keyrings/cri-o-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] \
https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | tee /etc/apt/sources.list.d/cri-o.list

    apt-get update
    apt-get install -y cri-o

    systemctl enable --now crio

    if ! systemctl is-active --quiet crio; then
        log "ERROR" "CRI-O failed to start"
        systemctl status crio
        exit 1
    fi

    log "INFO" "CRI-O installed successfully"
}

# ----------------------------
# Install Kubernetes
# ----------------------------
install_kubernetes() {
    log "INFO" "Installing Kubernetes ${KUBERNETES_VERSION}..."

    mkdir -p -m 755 /etc/apt/keyrings

    curl -4 -fsSL \
        "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
    chmod 644 /etc/apt/keyrings/kubernetes.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] \
https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubelet kubeadm kubectl

    apt-mark hold kubelet kubeadm kubectl

    local_ip=$(hostname -I | awk '{print $1}')
    if [ -z "$local_ip" ]; then
        log "ERROR" "Failed to detect local IP"
        exit 1
    fi

    echo "KUBELET_EXTRA_ARGS=--node-ip=${local_ip}" \
        > /etc/default/kubelet

    systemctl enable kubelet

    log "INFO" "Kubernetes components installed successfully"
}

# ----------------------------
# Main
# ----------------------------
main() {
    log "INFO" "Starting node setup..."

    disable_swap
    configure_dns
    container_runtime_setup
    install_crio
    install_kubernetes

    log "INFO" "Node setup completed successfully"
    chmod 644 "$SETUP_LOG"
}

main "$@"

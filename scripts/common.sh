#!/usr/bin/env bash

# Strict error handling
set -euxo pipefail

# Global variables
SETUP_LOG=${SETUP_LOG:-"/var/log/k8s-setup.log"}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Enhanced error handling with logging
error_handler() {
    local exit_code=$1
    local line_number=$2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - Error on line ${line_number}: Command exited with status ${exit_code}" | 
        tee -a "${SETUP_LOG}"
    exit "${exit_code}"
}
trap 'error_handler $? $LINENO' ERR

# Logging function
log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${SETUP_LOG}"
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    log "ERROR" "This script must be run with root privileges"
    exit 1
fi

# Version validation patterns
KUBERNETES_VERSION_PATTERN='^v[0-9]+\.[0-9]+$'
CRIO_VERSION_PATTERN='^v[0-9]+\.[0-9]+$'

# Check required environment variables
required_vars=(
    "DNS_SERVERS"
    "KUBERNETES_VERSION"
    "CRIO_VERSION"
    "OS"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        log "ERROR" "$var is not set"
        exit 1
    fi
done

# Validate version formats
if ! [[ $KUBERNETES_VERSION =~ $KUBERNETES_VERSION_PATTERN ]]; then
    log "ERROR" "KUBERNETES_VERSION must be in format vX.Y.Z (e.g., v1.30)"
    exit 1
fi

if ! [[ $CRIO_VERSION =~ $CRIO_VERSION_PATTERN ]]; then
    log "ERROR" "CRIO_VERSION must be in format vX.Y (e.g., v1.30)"
    exit 1
fi

# Disable swap
disable_swap() {
sudo swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
}

# Configure DNS settings
configure_dns() {
    log "INFO" "Configuring DNS settings..."
    
    if ! echo "$DNS_SERVERS" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$'; then
        log "ERROR" "Invalid DNS_SERVERS format"
        exit 1
    fi

    mkdir -p /etc/systemd/resolved.conf.d/
    cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
DNSStubListener=no
EOF

    systemctl restart systemd-resolved
    systemctl status systemd-resolved --no-pager || true
}

# Configure container runtime prerequisites
container_runtime_setup() {
    log "INFO" "Setting up container runtime prerequisites..."
    
    cat <<EOF | sudo tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

    # Load kernel modules
    for module in overlay br_netfilter; do
        if ! lsmod | grep -q "^$module"; then
            log "INFO" "Loading kernel module: $module"
            modprobe "$module"
        fi
    done

    # Configure sysctl parameters
    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system
}

# Install and configure CRI-O
install_crio() {
    log "INFO" "Installing CRI-O version ${CRIO_VERSION}..."
    
    # Install prerequisites
    log "INFO" "Installing prerequisites..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg
    
    # Create keyrings directory
    sudo mkdir -p -m 755 /etc/apt/keyrings

    # Retry mechanism for downloading GPG key
    local max_attempts=5
    local attempt=1
    local success=false

    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log "INFO" "Attempting to download CRI-O GPG key (attempt $attempt/$max_attempts)..."
        
        if curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" | \
            sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg; then
            success=true
            log "INFO" "Successfully downloaded CRI-O GPG key"
        else
            log "WARN" "Failed to download CRI-O GPG key (attempt $attempt/$max_attempts)"
            if [ $attempt -lt $max_attempts ]; then
                sleep $((attempt * 5))
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [ "$success" = false ]; then
        log "ERROR" "Failed to download CRI-O GPG key after $max_attempts attempts"
        log "ERROR" "Please check your internet connection and DNS settings"
        exit 1
    fi

    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/cri-o.list

    # Install CRI-O with retry mechanism
    for i in {1..5}; do
        if apt-get update && apt-get install -y cri-o; then
            log "INFO" "Successfully installed CRI-O"
            break
        fi
        if [ $i -eq 5 ]; then
            log "ERROR" "Failed to install CRI-O after 5 attempts"
            exit 1
        fi
        log "WARN" "CRI-O installation attempt $i failed. Retrying..."
        sleep 10
    done

    # Configure CRI-O
    mkdir -p /etc/crio/crio.conf.d/
    cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-crio.conf
[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "systemd"
default_capabilities = [
    "CHOWN",
    "DAC_OVERRIDE",
    "FSETID",
    "FOWNER",
    "SETGID",
    "SETUID",
    "SETPCAP",
    "NET_BIND_SERVICE",
    "KILL"
]
default_ulimits = [
    "nofile=1048576:1048576"
]

[crio.image]
pause_image = "registry.k8s.io/pause:3.9"
max_parallel_pulls = 5

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = ["/opt/cni/bin"]

[crio.metrics]
enable_metrics = true
metrics_port = 9537
EOF

    # Add environment variables if specified
    if [ ! -z "${ENVIRONMENT:-}" ]; then
        echo "${ENVIRONMENT}" | sudo tee -a /etc/default/crio
    fi

    systemctl daemon-reload
    systemctl enable --now crio
    
    # Verify installation
    if ! systemctl is-active --quiet crio; then
        log "ERROR" "CRI-O service failed to start"
        systemctl status crio
        exit 1
    fi
    
    log "INFO" "CRI-O installation and configuration completed successfully"
}

# Install Kubernetes components
install_kubernetes() {
    log "INFO" "Installing Kubernetes version ${KUBERNETES_VERSION}..."

    # Install prerequisites
    log "INFO" "Installing prerequisites..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg
    
    # Create keyrings directory with proper permissions
    sudo mkdir -p -m 755 /etc/apt/keyrings
    
    # Retry mechanism for downloading GPG key
    local max_attempts=5
    local attempt=1
    local success=false

    # Add Kubernetes apt repository
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list

    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log "INFO" "Attempting to download Kubernetes GPG key (attempt $attempt/$max_attempts)..."
        

        if curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | \
            sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
            success=true
            log "INFO" "Successfully downloaded Kubernetes GPG key"
        else
            log "WARN" "Failed to download Kubernetes GPG key (attempt $attempt/$max_attempts)"
            if [ $attempt -lt $max_attempts ]; then
                sleep $((attempt * 5))
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [ "$success" = false ]; then
        log "ERROR" "Failed to download Kubernetes GPG key after $max_attempts attempts"
        log "ERROR" "Please check your internet connection and DNS settings"
        exit 1
    fi


    # Install Kubernetes packages with retry
    for i in {1..5}; do
        if apt-get update && apt-get install -y kubelet kubeadm kubectl; then
            log "INFO" "Successfully installed Kubernetes components"
            break
        fi
        if [ $i -eq 5 ]; then
            log "ERROR" "Failed to install Kubernetes components after 5 attempts"
            exit 1
        fi
        log "WARN" "Kubernetes installation attempt $i failed. Retrying..."
        sleep 10
    done

    # Hold package versions
    apt-mark hold kubelet kubeadm kubectl

    # Configure kubelet
    if ! local_ip="$(ip -j addr show eth1 | jq -r '.[].addr_info[] | select(.family == "inet").local')"; then
        log "ERROR" "Could not detect local IP address"
        exit 1
    fi

    mkdir -p /etc/default
    cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF

    # Add environment variables if specified
    if [ ! -z "${ENVIRONMENT:-}" ]; then
        echo "${ENVIRONMENT}" | sudo tee -a /etc/default/kubelet
    fi
}

# Main execution
main() {
    log "INFO" "Starting Kubernetes node setup..."
    
    disable_swap
    configure_dns
    container_runtime_setup
    install_crio
    install_kubernetes
    
    log "INFO" "Kubernetes node setup completed successfully"
}

main "$@"

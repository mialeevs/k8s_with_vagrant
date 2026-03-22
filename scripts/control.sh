#!/usr/bin/env bash
#
# Kubernetes Control Plane Setup Script

set -euxo pipefail

SETUP_LOG=${SETUP_LOG:-"/var/log/k8s-control-setup.log"}
TEMP_DIR=$(mktemp -d)
CONFIG_PATH="/vagrant/configs"
CALICO_VERSION=${CALICO_VERSION:-"v3.28.2"}
CONTROL_IP=${CONTROL_IP:-"192.168.1.100"}
POD_CIDR=${POD_CIDR:-"10.244.0.0/16"}
SERVICE_CIDR=${SERVICE_CIDR:-"10.96.0.0/12"}

trap 'rm -rf "${TEMP_DIR}"' EXIT

log() {
    local level="$1"
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${SETUP_LOG}"
}

error_handler() {
    local exit_code=$1
    local line_number=$2
    log "ERROR" "Error on line ${line_number}: Command exited with status ${exit_code}"
    cleanup_on_failure
    exit "${exit_code}"
}
trap 'error_handler $? $LINENO' ERR

cleanup_on_failure() {
    log "INFO" "Performing cleanup after failure..."
    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* || true
    iptables -F || true
    iptables -t nat -F || true
}

wait_for_apiserver() {
    log "INFO" "Waiting for API server..."
    local timeout=180
    local interval=5
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl get nodes &>/dev/null; then
            log "INFO" "API server is ready"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log "INFO" "Waiting for API server... ($elapsed/$timeout seconds)"
    done
    log "ERROR" "Timeout waiting for API server"
    exit 1
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    log "INFO" "Waiting for pods in $namespace with selector $label..."
    kubectl wait --for=condition=Ready pods -n "$namespace" -l "$label" --timeout=${timeout}s || true

    local elapsed=0
    local interval=10
    while [ $elapsed -lt $timeout ]; do
        local total
        local ready
        total=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l || echo 0)
        ready=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o true | wc -l || echo 0)
        if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
            log "INFO" "All pods are ready ($ready/$total)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log "INFO" "Waiting for pods to be ready... ($elapsed/$timeout seconds)"
    done
    log "WARN" "Pods $label in $namespace may not be ready after $timeout seconds"
    kubectl get pods -n "$namespace" -l "$label" -o wide
}

# Ensure CALICO_VERSION has the v prefix
normalize_calico_version() {
    if [[ "${CALICO_VERSION}" != v* ]]; then
        CALICO_VERSION="v${CALICO_VERSION}"
    fi
}

initialize_control_plane() {
    log "INFO" "Initializing control plane..."
    cat <<EOF > "${TEMP_DIR}/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CONTROL_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///var/run/crio/crio.sock"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  serviceSubnet: "${SERVICE_CIDR}"
  podSubnet: "${POD_CIDR}"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    - name: "authorization-mode"
      value: "Node,RBAC"
    - name: "enable-admission-plugins"
      value: "NodeRestriction"
controllerManager:
  extraArgs:
    - name: "bind-address"
      value: "127.0.0.1"
scheduler:
  extraArgs:
    - name: "bind-address"
      value: "127.0.0.1"
EOF

    kubeadm config images pull --config "${TEMP_DIR}/kubeadm-config.yaml"
    kubeadm init --config "${TEMP_DIR}/kubeadm-config.yaml" --upload-certs

    mkdir -p /home/vagrant/.kube
    cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
    chown -R vagrant:vagrant /home/vagrant/.kube
    chmod 600 /home/vagrant/.kube/config
    export KUBECONFIG=/etc/kubernetes/admin.conf

    wait_for_apiserver

    # Generate join script for workers
    log "INFO" "Generating worker join script..."
    mkdir -p "${CONFIG_PATH}"
    kubeadm token create --print-join-command > "${CONFIG_PATH}/join.sh"
    chmod 755 "${CONFIG_PATH}/join.sh"

    cat >> /home/vagrant/.bashrc <<'EOF'
source <(kubectl completion bash)
complete -F __start_kubectl k
alias k=kubectl
alias c=clear
EOF
}

install_calico() {
    log "INFO" "Installing Calico CNI ${CALICO_VERSION}..."

    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o "${TEMP_DIR}/calico.yaml"
    sed -i "s#192.168.0.0/16#${POD_CIDR}#g" "${TEMP_DIR}/calico.yaml"
    sed -i '/name: CALICO_IPV4POOL_CIDR/a\            - name: IP_AUTODETECTION_METHOD\n              value: "interface=eth1"' "${TEMP_DIR}/calico.yaml"

    kubectl apply -f "${TEMP_DIR}/calico.yaml"

    wait_for_pods "kube-system" "k8s-app=kube-dns"
    wait_for_pods "kube-system" "k8s-app=calico-node"
}

install_tools() {
    log "INFO" "Installing Helm and ArgoCD CLI..."
    apt-get install -y unzip curl wget bash-completion

    # Helm
    curl -fsSL -o "${TEMP_DIR}/get_helm.sh" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 "${TEMP_DIR}/get_helm.sh"
    VERIFY_CHECKSUM=true "${TEMP_DIR}/get_helm.sh"

    # ArgoCD CLI
    wget -q https://github.com/argoproj/argo-cd/releases/download/v2.13.2/argocd-linux-amd64 -O "${TEMP_DIR}/argocd"
    install -m 755 "${TEMP_DIR}/argocd" /usr/local/bin/argocd
}

install_argocd() {
    log "INFO" "Installing ArgoCD..."
    kubectl create namespace argocd || true
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
    kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'
    kubectl patch svc argocd-server -n argocd --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30903},{"op":"replace","path":"/spec/ports/1/nodePort","value":30904}]'
}

main() {
    log "INFO" "Starting control plane setup..."
    normalize_calico_version
    initialize_control_plane
    install_calico
    install_tools
    install_argocd
    log "INFO" "Control plane setup completed successfully"
    chmod 644 "${SETUP_LOG}"
}

main "$@"

# Kubernetes Cluster on macOS with Vagrant and Parallels

A production-ready Kubernetes cluster setup using Vagrant, Parallels Desktop, CRI-O runtime, and Calico networking. Includes ArgoCD and Helm pre-installed.

## Prerequisites

### Required Software

Install Xcode Command Line Tools (provides `make`, `git`, and other essentials):
```bash
xcode-select --install
```

Then install the following:

> [Parallels Desktop](https://www.parallels.com/)

> [Vagrant](https://www.vagrantup.com/) - Version 2.3.0 or higher

### System Requirements

- Host Machine: 16GB RAM minimum (recommended: 32GB)
- Disk Space: 50GB free space
- CPU: 4+ cores recommended
- OS: macOS

### Install Vagrant Plugin

```bash
vagrant plugin install vagrant-parallels
```

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/mialeevs/kube_vagrant.git
cd kube_vagrant
```

### 2. Configure Your Cluster

Edit `settings.yaml` to customize:
- Number of worker nodes (default: 1)
- Memory and CPU allocation
- Network settings
- Kubernetes version

```yaml
nodes:
  control:
    cpu: 2
    memory: 6144
  workers:
    count: 1  # Change this to add more workers
    cpu: 2
    memory: 6144
```

### 3. Start the Cluster

```bash
make up
```

This will:
1. Validate `settings.yaml` configuration
2. Create all VMs sequentially without provisioning
3. Provision the control plane first (Kubernetes init, Calico, ArgoCD, Helm)
4. Provision each worker node sequentially (join cluster, install node exporter)

Initial setup takes 10-15 minutes depending on your internet speed.

### 4. List All Available Commands

```bash
make help
```

## Accessing the Cluster

### From Control Plane Node

```bash
make ssh-control
kubectl get nodes
kubectl get pods -A
```

### From Host Machine

Export kubeconfig to your host:
```bash
make kubeconfig
export KUBECONFIG=~/.kube/config-vagrant
kubectl get nodes
```

## Installed Components

### Core Components
- **Kubernetes**: v1.34
- **Container Runtime**: CRI-O v1.35
- **CNI**: Calico v3.28.2

### Additional Tools
- **ArgoCD**: v2.13.2 (GitOps)
- **Helm**: v3 (Package Manager)

## ArgoCD Access

ArgoCD is pre-installed and exposed via NodePort on the control plane.

### Port-Forward to Your Mac
```bash
make argocd-ui
```
This opens an SSH tunnel so you can access ArgoCD at:
```
https://localhost:8443

https://192.168.1.100:30904
```
Press `Ctrl+C` to stop the tunnel.

### Get Initial Admin Password
```bash
make argocd-password
```

### Login Credentials
- Username: `admin`
- Password: (from command above)

## Common Operations

### Check Cluster Status
```bash
make status
make pods
make nodes
```

### Validate Cluster Health
```bash
make validate
```

### Restart Cluster
```bash
make reload
```

### Stop Cluster
```bash
make down
```

### Destroy Cluster
```bash
make destroy
```

### Full Cleanup (remove all generated files)
```bash
make clean
```

### SSH to Nodes
```bash
make ssh-control
make ssh-worker
```

## Network Configuration

Default network settings:
- Control Plane IP: `192.168.1.100`
- Worker IPs: `192.168.1.11`, `192.168.1.12`, etc.
- Pod Network: `10.244.0.0/16`
- Service Network: `10.96.0.0/12`

Modify these in `settings.yaml` if they conflict with your network.

## Troubleshooting

### Cluster Not Starting

1. Check Vagrant status:
```bash
make status
```

2. View provisioning logs:
```bash
make logs-control
```

3. Check worker logs:
```bash
make logs-worker
```

### Nodes Not Joining

1. Verify join script exists:
```bash
cat configs/join.sh
```

2. Manually join a worker:
```bash
make ssh-worker
sudo bash /vagrant/configs/join.sh
```

3. Check network connectivity:
```bash
make ssh-worker
ping -c 3 192.168.1.100
```

### Pods Not Starting

1. Check pod status:
```bash
make ssh-control
kubectl describe pod <pod-name> -n <namespace>
```

2. Check CRI-O status:
```bash
make ssh-control
sudo systemctl status crio
```

3. Verify Calico is running:
```bash
make ssh-control
kubectl get pods -n kube-system -l k8s-app=calico-node
```

### DNS Issues

If pods can't resolve DNS:
```bash
make ssh-control
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Memory/Resource Issues

If nodes are running out of resources:
1. Increase memory in `settings.yaml`
2. Reload the cluster:
```bash
make reload
```

## Customization

### Change Kubernetes Version

Edit `settings.yaml`:
```yaml
software:
  kubernetes: v1.34  # Change to desired version
  crio: v1.35        # Should match or be compatible with Kubernetes version
```

### Add More Workers

Edit `settings.yaml`:
```yaml
nodes:
  workers:
    count: 3  # Increase number of workers
```

Then run:
```bash
make up
```

### Modify Resource Allocation

Edit `settings.yaml`:
```yaml
nodes:
  control:
    cpu: 4
    memory: 8192
  workers:
    cpu: 4
    memory: 8192
```

## Useful Aliases

The following aliases are pre-configured on the control plane node:
- `k` = `kubectl`
- `c` = `clear`

## Project Structure

```
.
├── Makefile              # Command interface (run make help)
├── Vagrantfile           # Main Vagrant configuration
├── settings.yaml         # Cluster configuration
├── scripts/
│   ├── common.sh         # Common setup for all nodes
│   ├── control.sh        # Control plane specific setup
│   ├── node.sh           # Worker node specific setup
│   └── validate-settings.sh  # Pre-flight settings validation
└── configs/
    └── join.sh           # Auto-generated cluster join command
```

## Contributing

Feel free to submit issues and enhancement requests!

## License

See LICENSE file for details.
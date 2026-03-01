# Kubernetes Installation on Ubuntu 24.04/Windows 11 with VAGRANT

A production-ready Kubernetes cluster setup using Vagrant, CRI-O runtime, and Calico networking. Includes ArgoCD, Helm, AWS CLI, and metrics server pre-installed.

## Prerequisites

### Required Software

Install the following on your laptop or PC:

> [VMWare Workstation](https://access.broadcom.com/default/ui/v1/signin/) or [Parallels Desktop](https://www.parallels.com/) (for macOS)

> [Vagrant](https://www.vagrantup.com/) - Version 2.3.0 or higher

> [GIT](https://git-scm.com/)

> [VMWare Desktop Plugin](https://developer.hashicorp.com/vagrant/docs/providers/vmware/vagrant-vmware-utility) (for VMware users)

### System Requirements

- Host Machine: 16GB RAM minimum (recommended: 32GB)
- Disk Space: 50GB free space
- CPU: 4+ cores recommended
- OS: Windows 10/11, macOS, or Linux

### Install Vagrant Plugins

For VMware users:
```bash
vagrant plugin install vagrant-vmware-desktop
vagrant plugin install vagrant-hostmanager
```

For Parallels users (macOS):
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
vagrant up
```

This will:
- Provision 1 control plane node + N worker nodes
- Install Kubernetes v1.30 with CRI-O runtime
- Deploy Calico CNI
- Install ArgoCD, Helm, AWS CLI, and metrics server
- Configure the cluster and join worker nodes

Initial setup takes 10-15 minutes depending on your internet speed.

## Accessing the Cluster

### From Control Plane Node

```bash
vagrant ssh control-plane
kubectl get nodes
kubectl get pods -A
```

### From Host Machine

Copy kubeconfig from control plane:
```bash
vagrant ssh control-plane -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-vagrant
export KUBECONFIG=~/.kube/config-vagrant
kubectl get nodes
```

## Installed Components

### Core Components
- **Kubernetes**: v1.30
- **Container Runtime**: CRI-O v1.30
- **CNI**: Calico v3.28.2
- **Metrics Server**: Latest

### Additional Tools
- **ArgoCD**: v2.13.2 (GitOps)
- **Helm**: v3 (Package Manager)
- **AWS CLI**: v2 (Cloud Integration)

## ArgoCD Access

ArgoCD is pre-installed and exposed via NodePort.

### Access URL
```
https://192.168.1.100:30904
```

### Get Initial Admin Password
```bash
vagrant ssh control-plane
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Login Credentials
- Username: `admin`
- Password: (from command above)

## Common Operations

### Check Cluster Status
```bash
vagrant ssh control-plane -c "kubectl get nodes -o wide"
vagrant ssh control-plane -c "kubectl get pods -A"
```

### Restart Cluster
```bash
vagrant reload
```

### Stop Cluster
```bash
vagrant halt
```

### Destroy Cluster
```bash
vagrant destroy -f
```

### SSH to Nodes
```bash
vagrant ssh control-plane
vagrant ssh worker1
vagrant ssh worker2  # if you have multiple workers
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
vagrant status
```

2. View provisioning logs:
```bash
vagrant ssh control-plane -c "sudo cat /var/log/k8s-setup.log"
vagrant ssh control-plane -c "sudo cat /var/log/k8s-control-setup.log"
```

3. Check worker logs:
```bash
vagrant ssh worker1 -c "sudo cat /var/log/k8s-worker-setup.log"
```

### Nodes Not Joining

1. Verify join script exists:
```bash
cat configs/join.sh
```

2. Manually join a worker:
```bash
vagrant ssh worker1
sudo bash /vagrant/configs/join.sh
```

3. Check network connectivity:
```bash
vagrant ssh worker1 -c "ping -c 3 192.168.1.100"
```

### Pods Not Starting

1. Check pod status:
```bash
vagrant ssh control-plane -c "kubectl describe pod <pod-name> -n <namespace>"
```

2. Check CRI-O status:
```bash
vagrant ssh control-plane -c "sudo systemctl status crio"
```

3. Verify Calico is running:
```bash
vagrant ssh control-plane -c "kubectl get pods -n kube-system -l k8s-app=calico-node"
```

### DNS Issues

If pods can't resolve DNS:
```bash
vagrant ssh control-plane -c "kubectl get pods -n kube-system -l k8s-app=kube-dns"
```

Check CoreDNS logs:
```bash
vagrant ssh control-plane -c "kubectl logs -n kube-system -l k8s-app=kube-dns"
```

### Memory/Resource Issues

If nodes are running out of resources:
1. Increase memory in `settings.yaml`
2. Reload the cluster:
```bash
vagrant reload
```

## Customization

### Change Kubernetes Version

Edit `settings.yaml`:
```yaml
software:
  kubernetes: v1.30  # Change to v1.29, v1.31, etc.
  crio: v1.30        # Must match Kubernetes major.minor version
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
vagrant up
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

The following aliases are pre-configured on all nodes:
- `k` = `kubectl`
- `c` = `clear`
- `ud` = `sudo apt update -y && sudo apt upgrade -y`

## Project Structure

```
.
├── Vagrantfile           # Main Vagrant configuration
├── settings.yaml         # Cluster configuration
├── scripts/
│   ├── common.sh        # Common setup for all nodes
│   ├── control.sh       # Control plane specific setup
│   └── node.sh          # Worker node specific setup
└── configs/
    └── join.sh          # Auto-generated cluster join command
```

## Contributing

Feel free to submit issues and enhancement requests!

## License

See LICENSE file for details.
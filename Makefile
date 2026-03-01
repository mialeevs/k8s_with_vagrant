.PHONY: help up down destroy status ssh-control ssh-worker logs clean validate argocd-password

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: validate-config ## Start the Kubernetes cluster
	@echo "Starting Kubernetes cluster..."
	vagrant up

validate-config: ## Validate settings.yaml configuration
	@bash scripts/validate-settings.sh

down: ## Stop the cluster (preserves state)
	@echo "Stopping cluster..."
	vagrant halt

destroy: ## Destroy the cluster completely
	@echo "Destroying cluster..."
	vagrant destroy -f

reload: ## Reload cluster configuration
	@echo "Reloading cluster..."
	vagrant reload

status: ## Show cluster status
	@echo "Cluster status:"
	@vagrant status
	@echo ""
	@echo "Kubernetes nodes:"
	@vagrant ssh control-plane -c "kubectl get nodes -o wide" 2>/dev/null || echo "Cluster not running"

ssh-control: ## SSH into control plane
	vagrant ssh control-plane

ssh-worker: ## SSH into worker1
	vagrant ssh worker1

logs-control: ## View control plane setup logs
	@vagrant ssh control-plane -c "sudo cat /var/log/k8s-setup.log && echo '' && sudo cat /var/log/k8s-control-setup.log"

logs-worker: ## View worker node setup logs
	@vagrant ssh worker1 -c "sudo cat /var/log/k8s-worker-setup.log"

pods: ## Show all pods in all namespaces
	@vagrant ssh control-plane -c "kubectl get pods -A -o wide"

nodes: ## Show detailed node information
	@vagrant ssh control-plane -c "kubectl get nodes -o wide && echo '' && kubectl top nodes 2>/dev/null || echo 'Metrics not available yet'"

argocd-password: ## Get ArgoCD admin password
	@echo "ArgoCD Admin Password:"
	@vagrant ssh control-plane -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d && echo ''" || echo "ArgoCD not ready yet"
	@echo ""
	@echo "Access ArgoCD at: https://192.168.1.100:30904"
	@echo "Username: admin"

argocd-url: ## Show ArgoCD access information
	@echo "ArgoCD Access Information:"
	@echo "=========================="
	@echo "URL: https://192.168.1.100:30904"
	@echo "Username: admin"
	@echo "Password: Run 'make argocd-password' to retrieve"

validate: ## Validate cluster health
	@echo "Validating cluster health..."
	@vagrant ssh control-plane -c "kubectl get nodes && kubectl get pods -A && kubectl cluster-info"

clean: ## Clean up generated files
	@echo "Cleaning up..."
	rm -rf .vagrant/
	rm -f configs/join.sh
	@echo "Done. Run 'make up' to recreate cluster."

kubeconfig: ## Export kubeconfig to host
	@echo "Exporting kubeconfig..."
	@mkdir -p ~/.kube
	@vagrant ssh control-plane -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-vagrant
	@echo "Kubeconfig exported to ~/.kube/config-vagrant"
	@echo "Use: export KUBECONFIG=~/.kube/config-vagrant"

info: ## Show cluster information
	@echo "Cluster Information:"
	@echo "==================="
	@echo "Control Plane: 192.168.1.100"
	@echo "ArgoCD: https://192.168.1.100:30904"
	@echo ""
	@vagrant ssh control-plane -c "kubectl version --short 2>/dev/null || kubectl version" || echo "Cluster not running"

.PHONY: help up down destroy reload status ssh-control ssh-worker \
       logs-control logs-worker pods nodes validate clean kubeconfig \
       argocd-password info

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: ## Start the Kubernetes cluster
	@echo "==> Creating all VMs (no provisioning)..."
	vagrant up --no-provision
	@echo "==> Provisioning control-plane..."
	vagrant provision control-plane
	@echo "==> Provisioning worker nodes sequentially..."
	@for i in $$(seq 1 $$(grep 'count:' settings.yaml | awk '{print $$2}')); do \
		echo "==> Provisioning worker$$i..."; \
		vagrant provision worker$$i; \
	done
	@echo "==> All nodes provisioned."

down: ## Stop the cluster (preserves state)
	@echo "Stopping cluster..."
	vagrant halt

destroy: ## Destroy the cluster completely
	@echo "Destroying cluster..."
	vagrant destroy -f

reload: ## Reload cluster configuration
	@echo "Reloading cluster..."
	vagrant reload --no-provision
	@echo "==> Re-provisioning control-plane..."
	vagrant provision control-plane
	@echo "==> Re-provisioning worker nodes sequentially..."
	@for i in $$(seq 1 $$(grep 'count:' settings.yaml | awk '{print $$2}')); do \
		echo "==> Re-provisioning worker$$i..."; \
		vagrant provision worker$$i; \
	done

status: ## Show cluster status
	@vagrant status
	@echo ""
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
	@vagrant ssh control-plane -c "kubectl get nodes -o wide"

argocd-password: ## Get ArgoCD admin password
	@vagrant ssh control-plane -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d && echo ''" || echo "ArgoCD not ready yet"

validate: ## Validate cluster health
	@vagrant ssh control-plane -c "kubectl get nodes && kubectl get pods -A && kubectl cluster-info"

clean: ## Clean up generated files
	rm -rf .vagrant/
	rm -f configs/join.sh
	@echo "Done. Run 'make up' to recreate cluster."

kubeconfig: ## Export kubeconfig to host
	@mkdir -p ~/.kube
	@vagrant ssh control-plane -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-vagrant
	@chmod 600 ~/.kube/config-vagrant
	@echo "Kubeconfig exported to ~/.kube/config-vagrant"
	@echo "Use: export KUBECONFIG=~/.kube/config-vagrant"

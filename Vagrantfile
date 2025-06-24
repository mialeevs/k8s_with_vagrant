require 'yaml'


def load_settings
  YAML.load_file('settings.yaml')
end

Vagrant.configure("2") do |config|
  settings = load_settings

  config.vm.box = settings["software"]["box"]
  config.vm.box_check_update = true

  config.vm.synced_folder '.', '/vagrant', disabled: true
  config.vm.synced_folder "configs", "/vagrant/configs"

  # === Control Plane ===
  config.vm.define "control-plane" do |node|
    node.vm.hostname = "control-plane"
    node.vm.boot_timeout = 1500
    node.vm.network "private_network", ip: settings["network"]["control_ip"]

    node.vm.provider "parallels" do |prl|
      prl.memory = settings["nodes"]["control"]["memory"]
      prl.cpus = settings["nodes"]["control"]["cpu"]
      prl.update_guest_tools = true
      
    end

    node.vm.communicator = "ssh"
    node.ssh.username = "vagrant"
    node.ssh.private_key_path = "~/.vagrant.d/insecure_private_key"
    node.ssh.insert_key = false

    node.vm.provision 'shell',
      env: {
        'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
        'ENVIRONMENT' => settings['environment'],
        'KUBERNETES_VERSION' => settings['software']['kubernetes'],
        'CRIO_VERSION' => settings['software']['crio'],
        'OS' => settings['software']['os'],
        'SETUP_LOG' => '/var/log/k8s-setup.log'
      },
      path: 'scripts/common.sh'

    node.vm.provision 'shell',
      env: {
        'CALICO_VERSION' => settings['software']['calico'],
        'POD_CIDR' => settings['network']['pod_cidr'],
        'SERVICE_CIDR' => settings['network']['service_cidr'],
        'CONTROL_IP' => settings['network']['control_ip']
      },
      path: 'scripts/control.sh'
  end

  # === Worker Nodes ===
  (1..settings["nodes"]["workers"]["count"]).each do |i|
    worker_name = "worker#{i}"
    worker_ip = "#{settings['network']['worker_ip_prefix']}.#{10 + i}"

    config.vm.define worker_name do |node|
      node.vm.hostname = worker_name
      node.vm.boot_timeout = 1500
      node.vm.network "private_network", ip: worker_ip

      node.vm.provider "parallels" do |prl|
        prl.memory = settings["nodes"]["workers"]["memory"]
        prl.cpus = settings["nodes"]["workers"]["cpu"]
        prl.update_guest_tools = true
      end

      node.vm.communicator = "ssh"
      node.ssh.username = "vagrant"
      node.ssh.private_key_path = "~/.vagrant.d/insecure_private_key"
      node.ssh.insert_key = false

      node.vm.provision 'shell',
        env: {
          'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
          'ENVIRONMENT' => settings['environment'],
          'KUBERNETES_VERSION' => settings['software']['kubernetes'],
          'CRIO_VERSION' => settings['software']['crio'],
          'OS' => settings['software']['os'],
          'SETUP_LOG' => '/var/log/k8s-setup.log'
        },
        path: 'scripts/common.sh'

      node.vm.provision 'shell', path: 'scripts/node.sh'
    end
  end

  # === Trigger to check cluster health ===
  config.trigger.after [:up, :reload] do |trigger|
    trigger.name = "Verifying cluster health"
    trigger.ruby do |env, machine|
      system <<~SHELL
        echo "Checking cluster status..."
        vagrant ssh control-plane -c "kubectl get nodes -o wide"
        vagrant ssh control-plane -c "kubectl get pods -A"
        vagrant ssh control-plane -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
      SHELL
    end
  end
end

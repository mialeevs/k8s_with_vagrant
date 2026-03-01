require 'yaml'

def load_settings
  YAML.safe_load(File.read('settings.yaml'), aliases: true)
end

Vagrant.configure("2") do |config|
  settings = load_settings

  # === Basic Validation ===
  raise "Missing software.box" unless settings.dig("software", "box")
  raise "Missing network.control_ip" unless settings.dig("network", "control_ip")

  config.vm.box = settings["software"]["box"]
  config.vm.box_check_update = true

  # Disable default shared folder
  config.vm.synced_folder '.', '/vagrant', disabled: true

  # === Dynamic Shared Folders ===
  Array(settings["shared_folders"]).each do |folder|
    config.vm.synced_folder folder["host_path"], folder["vm_path"],
      owner: folder["owner"],
      group: folder["group"],
      mount_options: folder["mount_options"]
  end

  # =========================
  # === Control Plane Node ==
  # =========================
  config.vm.define "control-plane" do |node|
    node.vm.hostname = "control-plane"
    node.vm.boot_timeout = 900
    node.vm.network "private_network", ip: settings["network"]["control_ip"]

    node.vm.provider "parallels" do |prl|
      prl.memory = settings["nodes"]["control"]["memory"]
      prl.cpus   = settings["nodes"]["control"]["cpu"]
      prl.update_guest_tools = true
    end

    node.vm.communicator = "ssh"

    node.vm.provision 'shell',
      env: {
        'DNS_SERVERS'        => Array(settings.dig('network', 'dns_servers')).join(','),
        'ENVIRONMENT'        => settings['environment'],
        'KUBERNETES_VERSION' => settings['software']['kubernetes'],
        'CRIO_VERSION'       => settings['software']['crio'],
        'OS'                 => settings['software']['os'],
        'SETUP_LOG'          => '/var/log/k8s-setup.log'
      },
      path: 'scripts/common.sh'

    node.vm.provision 'shell',
      env: {
        'CALICO_VERSION' => settings['software']['calico'],
        'POD_CIDR'       => settings['network']['pod_cidr'],
        'SERVICE_CIDR'   => settings['network']['service_cidr'],
        'CONTROL_IP'     => settings['network']['control_ip']
      },
      path: 'scripts/control.sh'
  end

  # =====================
  # === Worker Nodes ====
  # =====================
  worker_count = settings.dig("nodes", "workers", "count") || 0
  worker_start_ip = settings.dig("network", "worker_start_ip") || 11
  worker_prefix = settings.dig("network", "worker_ip_prefix")

  (1..worker_count).each do |i|
    worker_name = "worker#{i}"
    worker_ip = "#{worker_prefix}.#{worker_start_ip + i - 1}"

    config.vm.define worker_name do |node|
      node.vm.hostname = worker_name
      node.vm.boot_timeout = 900
      node.vm.network "private_network", ip: worker_ip

      node.vm.provider "parallels" do |prl|
        prl.memory = settings["nodes"]["workers"]["memory"]
        prl.cpus   = settings["nodes"]["workers"]["cpu"]
        prl.update_guest_tools = true
      end

      node.vm.communicator = "ssh"

      node.vm.provision 'shell',
        env: {
          'DNS_SERVERS'        => Array(settings.dig('network', 'dns_servers')).join(','),
          'ENVIRONMENT'        => settings['environment'],
          'KUBERNETES_VERSION' => settings['software']['kubernetes'],
          'CRIO_VERSION'       => settings['software']['crio'],
          'OS'                 => settings['software']['os'],
          'CONTROL_IP'         => settings['network']['control_ip'],
          'SETUP_LOG'          => '/var/log/k8s-setup.log'
        },
        path: 'scripts/common.sh'

      node.vm.provision 'shell',
        env: {
          'CONTROL_IP' => settings['network']['control_ip']
        },
        path: 'scripts/node.sh'
    end
  end

  # ==============================
  # === Post-Cluster Health Check
  # ==============================
  config.trigger.after [:up, :reload] do |trigger|
    trigger.name = "Verifying cluster health"
    trigger.ruby do |_env, _machine|
      system <<~SHELL
        echo "Checking cluster status..."
        vagrant ssh control-plane -c "kubectl get nodes -o wide"
        vagrant ssh control-plane -c "kubectl get pods -A"
        vagrant ssh control-plane -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
      SHELL
    end
  end
end
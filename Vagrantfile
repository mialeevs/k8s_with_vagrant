require 'yaml'
require 'fileutils'
require 'open3'

class VagrantConfigError < StandardError; end

def load_settings
  settings_file = 'settings.yaml'
  raise VagrantConfigError, "Settings file '#{settings_file}' not found!" unless File.exist?(settings_file)

  begin
    YAML.load_file(settings_file)
  rescue StandardError => e
    raise VagrantConfigError, "Error loading settings: #{e.message}"
  end
end

Vagrant.configure('2') do |config|
  settings = load_settings

  config.vm.provider 'virtualbox' do |vb|
    vb.customize ['modifyvm', :id, '--clipboard-mode', 'disabled']
    vb.customize ['modifyvm', :id, '--drag-and-drop', 'disabled']
    vb.customize ['modifyvm', :id, '--audio', 'none']
    vb.customize ['modifyvm', :id, '--usb', 'off']
    vb.customize ['modifyvm', :id, '--vrde', 'off']

    vb.customize ['modifyvm', :id, '--hwvirtex', 'on']
    vb.customize ['modifyvm', :id, '--vtxvpid', 'on']
    vb.customize ['modifyvm', :id, '--vtxux', 'on']
    vb.customize ['modifyvm', :id, '--paravirtprovider', 'kvm']
    vb.customize ['modifyvm', :id, '--largepages', 'on']
    vb.customize ['modifyvm', :id, '--nestedpaging', 'on']
    vb.customize ['modifyvm', :id, '--pagefusion', 'off']

    vb.customize ['storagectl', :id, '--name', 'SATA Controller', '--hostiocache', 'on']
  end

  config.vm.box = if `uname -m`.strip == 'aarch64'
    "#{settings['software']['box']}-arm64"
  else
    settings['software']['box']
  end

  config.vm.box_check_update = true

  config.vm.synced_folder '.', '/vagrant', disabled: true

  config.vm.synced_folder './configs', '/vagrant/configs',
    owner: 'vagrant',
    group: 'vagrant',
    mount_options: ['dmode=750,fmode=640'],
    create: true

  config.vm.define 'control-plane', primary: true do |control|
    control.vm.hostname = 'control-node'
    control.vm.boot_timeout = 1500

    control.vm.network 'public_network',
      ip: settings['network']['control_ip'],
      bridge: settings['network']['bridge_interface'],
      netmask: settings['network']['netmask'],
      nic_type: 'virtio'

    control.vm.network 'private_network',
      ip: "#{settings['network']['private_ip_prefix']}.10",
      virtualbox__intnet: 'cluster_internal',
      nic_type: 'virtio'

    control.vm.provider 'virtualbox' do |vb|
      vb.memory = settings['nodes']['control']['memory']
      vb.cpus = settings['nodes']['control']['cpu']

      disk_path = 'control_plane_disk.vdi'
      unless File.exist?(disk_path)
        vb.customize ['createhd', '--filename', disk_path, '--size', settings['nodes']['control']['disk_size'], '--variant', 'Fixed']
        vb.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_path]
      end
    end

    control.vm.provision 'shell',
      env: {
        'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
        'ENVIRONMENT' => settings['environment'],
        'KUBERNETES_VERSION' => settings['software']['kubernetes'],
        'CRIO_VERSION' => settings['software']['crio'],
        'OS' => settings['software']['os'],
        'SETUP_LOG' => '/var/log/k8s-setup.log'
      },
      path: 'scripts/common.sh'

    control.vm.provision 'shell',
      env: {
        'CALICO_VERSION' => settings['software']['calico'],
        'POD_CIDR' => settings['network']['pod_cidr'],
        'SERVICE_CIDR' => settings['network']['service_cidr'],
        'CONTROL_IP' => settings['network']['control_ip']
      },
      path: 'scripts/control.sh'
  end

  (1..settings['nodes']['workers']['count']).each do |i|
    config.vm.define "worker#{i}" do |worker|
      worker.vm.hostname = "worker-node#{i}"
      worker.vm.boot_timeout = 1500

      worker.vm.network 'public_network',
        ip: "#{settings['network']['worker_ip_prefix']}.#{i + 10}",
        bridge: settings['network']['bridge_interface'],
        netmask: settings['network']['netmask'],
        nic_type: 'virtio'

      worker.vm.network 'private_network',
        ip: "#{settings['network']['private_ip_prefix']}.#{i + 20}",
        virtualbox__intnet: 'cluster_internal',
        nic_type: 'virtio'

      worker.vm.provider 'virtualbox' do |vb|
        vb.memory = settings['nodes']['workers']['memory']
        vb.cpus = settings['nodes']['workers']['cpu']

        disk_path = "worker#{i}_disk.vdi"
        unless File.exist?(disk_path)
          vb.customize ['createhd', '--filename', disk_path, '--size', settings['nodes']['workers']['disk_size'], '--variant', 'Fixed']
          vb.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_path]
        end
      end

      worker.vm.provision 'shell',
        env: {
          'DNS_SERVERS' => settings['network']['dns_servers'].join(','),
          'ENVIRONMENT' => settings['environment'],
          'KUBERNETES_VERSION' => settings['software']['kubernetes'],
          'CRIO_VERSION' => settings['software']['crio'],
          'OS' => settings['software']['os'],
          'SETUP_LOG' => '/var/log/k8s-setup.log'
        },
        path: 'scripts/common.sh'

      worker.vm.provision 'shell', path: 'scripts/node.sh'
    end
  end

  config.trigger.after [:up, :reload] do |trigger|
    trigger.name = "Verifying cluster health"
    trigger.ruby do |env, machine|
      system(<<-SHELL
        echo "Checking cluster status..."
        vagrant ssh control-plane -c "kubectl get nodes -o wide"
        vagrant ssh control-plane -c "kubectl get pods -A"
        vagrant ssh control-plane -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
      SHELL
      )
    end
  end
end

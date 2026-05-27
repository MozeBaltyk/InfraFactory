locals {
  common_cloudinit = {
    for vm in local.all_vms_map :
    vm.name => templatefile(
      "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
      {
        ## Base OS
        os_name  = local.os.os_name
        hostname = vm.name
        fqdn     = "${vm.name}.${local.subdomain}"
        domain   = local.subdomain

        ## Node
        node_role     = vm.role
        node_username = var.cluster.username
        timezone      = var.cluster.timezone
        clusterid     = var.cluster.id

        ## Base OS upgrade
        package_upgrade_enabled = var.cluster.package_upgrade_enabled

        ## SSH
        public_key = tls_private_key.global_key.public_key_openssh

        ## Networking
        current_private_ip = vm.private_ip

        is_first_master = (
          vm.role == "master" &&
          vm.name == local.first_master_name
        )

        first_master_ip   = local.master_details[0].private_ip
        first_master_fqdn = local.first_master_fqdn

        ## Join endpoint
        cluster_join_endpoint = local.master_details[0].private_ip

        ## Disks
        extra_disks = try(local.vm_disks[vm.name], [])

        # Extra packages
        extra_packages = var.extra_packages
        
        #################################################
        # K3S
        #################################################

        k3s_token   = local.cluster_token
        k3s_version = var.k3s.version

        k3s_tls_sans = distinct(compact(concat(
          var.k3s.tls_sans,
          [local.master_details[0].private_ip],
          [local.first_master_fqdn],
          [for master in local.master_details : "${master.name}.${local.subdomain}"]
        )))

        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        #################################################
        # RKE2
        #################################################

        rke2_token   = local.cluster_token
        rke2_version = var.rke2.version

        rke2_tls_sans = distinct(compact(concat(
          var.rke2.tls_sans,
          [local.master_details[0].private_ip],
          [local.first_master_fqdn],
          [for master in local.master_details : "${master.name}.${local.subdomain}"]
        )))

        rke2_etcd_enabled           = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled  = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled = var.rke2.metrics_server_enabled

        #################################################
        # Ansible Pull
        #################################################

        ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
        ansible_pull_branch   = try(var.ansible.pull.branch, "main")
        ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
        ansible_pull_token    = try(var.ansible.pull.token, null)
        ansible_pull_timer    = try(var.ansible.pull.timer, null)
      }
    )
  }

  ##
  ## Private NIC netplan
  ##
  ## OVH instances have two NICs: a public one (ens3) and a private one
  ## (ens4) on the OpenStack subnet. The private subnet has DHCP enabled
  ## and once a gateway exists on it the DHCP server advertises a default
  ## route on the private NIC. Without override, that route competes with
  ## the public NIC's default route and breaks inbound SSH via asymmetric
  ## routing.
  ##
  ## We write a netplan that keeps DHCP on the private NIC (so it still
  ## receives the IP reserved by Terraform on the OpenStack port) but
  ## ignores the DHCP-supplied default route and DNS. On first boot this
  ## netplan file is not yet present when the network stage runs, so the
  ## route briefly appears. A systemd oneshot service (remove-ens4-route)
  ## runs after network-online.target but before ssh.service, deleting
  ## the competing route before SSH ever starts — no race, no netplan
  ## apply, no network restart. On subsequent boots the netplan file
  ## already exists so the route is never installed and the service is a
  ## no-op.
  ##

  ovh_private_netplan_yaml = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
    {
      interface_id         = "privatenic"
      interface_match_name = "ens4"

      use_dhcp           = true
      accept_dhcp_routes = false
      accept_dhcp_dns    = false

      ip_address  = ""
      cidr_prefix = ""

      network_gateway = null
      dns_servers     = null
      domain          = ""
    }
  )

  cloudinit_user_data = {
    for name, body in local.common_cloudinit :
    name => "#cloud-config\n${yamlencode(merge(
      yamldecode(body),
      {
        write_files = concat(
          try(yamldecode(body).write_files, []),
          [
            {
              path        = "/etc/netplan/99-infrafactory-private.yaml"
              permissions = "0600"
              owner       = "root:root"
              content     = local.ovh_private_netplan_yaml
            },
            {
              path        = "/etc/systemd/system/remove-ens4-route.service"
              permissions = "0644"
              owner       = "root:root"
              content     = <<-EOF
                [Unit]
                Description=Remove default route on ens4 (private NIC)
                After=network-online.target
                Before=ssh.service

                [Service]
                Type=oneshot
                ExecStart=/usr/bin/ip route del default dev ens4
                # Exit code 2 means "no such route" — fine on subsequent
                # boots where the netplan already prevents the route.
                SuccessExitStatus=2
                RemainAfterExit=yes

                [Install]
                WantedBy=multi-user.target
                EOF
            },
          ]
        )

        runcmd = concat(
          # Enable the oneshot service — on first boot it runs before SSH
          # and deletes any competing default route on the private NIC.
          # On subsequent boots the netplan is already in place so the
          # route never appears and this is a no-op.
          [
            ["systemctl", "daemon-reload"],
            ["systemctl", "enable", "remove-ens4-route.service"],
            ["systemctl", "start", "--no-block", "remove-ens4-route.service"],
          ],
          try(yamldecode(body).runcmd, [])
        )
      }
    ))}"
  }
}

resource "local_file" "ansible_config" {
  filename = "${local.env_path}/ansible.cfg"
  content  = <<-EOT
[defaults]
remote_user = ${var.cluster.username}
inventory =  ./hosts.ini
roles_path = ../../../ansible/roles
host_key_checking = false
display_skipped_hosts = false
deprecation_warnings = false
force_color       = True
stdout_callback   = yaml
private_key_file = ./.key.private
EOT

  depends_on = [null_resource.env_directory]
}

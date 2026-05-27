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
  ## Dual-NIC netplan via cloud-init's network config
  ##
  ## OVH instances have two NICs: ens3 (public) and ens4 (private, on the
  ## OpenStack subnet). We render the shared network_config.cfg.tftpl for
  ## each NIC and merge them into a single `network:` key in the cloud-config
  ## user_data. Cloud-init applies this during its early network stage,
  ## before SSH is available — avoiding the race that would occur if the
  ## private NIC's DHCP-supplied default route were only removed later (e.g.
  ## via write_files + runcmd).
  ##
  ## Public NIC (ens3): DHCP with routes and DNS — standard internet access.
  ## Private NIC (ens4): DHCP to receive the IP reserved by Terraform on the
  ##   OpenStack port, but with dhcp4-overrides to ignore the gateway/DNS that
  ##   OVH's DHCP server advertises once a gateway resource exists on the
  ##   subnet. Without this override, the private NIC would install a competing
  ##   default route that breaks inbound SSH (asymmetric return path).
  ##

  ovh_public_netplan_yaml = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
    {
      interface_id         = "publicnic"
      interface_match_name = "ens3"

      use_dhcp           = true
      accept_dhcp_routes = true
      accept_dhcp_dns    = true

      ip_address  = ""
      cidr_prefix = ""

      network_gateway = null
      dns_servers     = null
      domain          = ""
    }
  )

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

  ##
  ## Merge both NIC netplan sections into a single network config
  ## and inject it as the `network:` key in cloud-config user_data.
  ##

  ovh_combined_network = yamlencode({
    network = {
      version = 2
      ethernets = merge(
        yamldecode(local.ovh_public_netplan_yaml).network.ethernets,
        yamldecode(local.ovh_private_netplan_yaml).network.ethernets
      )
    }
  })

  cloudinit_user_data = {
    for name, body in local.common_cloudinit :
    name => "#cloud-config\n${yamlencode(merge(
      yamldecode(body),
      yamldecode(local.ovh_combined_network)
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

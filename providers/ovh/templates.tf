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

        rke2_etcd_enabled             = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled    = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled   = var.rke2.metrics_server_enabled
        rke2_cni                      = var.rke2.cni
        rke2_ingress_type             = var.rke2.ingress_type
        rke2_kube_proxy_enabled       = try(var.rke2.kube_proxy_enabled, true)
        rke2_cilium_hubble_enabled    = try(var.rke2.cilium.hubble_enabled, false)
        rke2_cilium_operator_replicas = try(var.rke2.cilium.operator_replicas, 1)

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
  ## Private NIC route cleanup — no competing default route
  ##
  ## OVH instances have two NICs: public and private. The private NIC gets
  ## its reserved IP from DHCP (the OpenStack port already pins
  ## ip = each.value.private_ip). However the subnet's DHCP server can also
  ## advertise a default route when a subnet gateway exists, which competes
  ## with the public NIC's default route and breaks inbound SSH via asymmetric
  ## routing.
  ##
  ## Let OpenStack metadata/cloud-init own NIC configuration. We only remove
  ## the default route from the NIC that received the deterministic private IP,
  ## and install a small timer so DHCP renewals or reboots cannot keep the
  ## private default route around.

  cloudinit_user_data = {
    for name, body in local.common_cloudinit :
    name => "#cloud-config\n${yamlencode(merge(
      yamldecode(body),
      {
        write_files = concat(
          try(yamldecode(body).write_files, []),
          [
            {
              path        = "/usr/local/sbin/infrafactory-ovh-private-route-cleanup"
              permissions = "0755"
              owner       = "root:root"
              content     = <<-SCRIPT
                #!/bin/sh
                set -eu

                PRIVATE_IP="${local.all_vms_map[name].private_ip}"

                i=0
                PRIVATE_IF=""
                while [ "$i" -lt 60 ]; do
                  PRIVATE_IF="$(ip -o -4 addr show | awk -v ip="$PRIVATE_IP" '$4 ~ "^" ip "/" {print $2; exit}')"
                  [ -n "$PRIVATE_IF" ] && break
                  i=$((i + 1))
                  sleep 1
                done

                if [ -z "$PRIVATE_IF" ]; then
                  echo "Unable to find OVH private interface for $PRIVATE_IP" >&2
                  exit 0
                fi

                while ip route show default dev "$PRIVATE_IF" | grep -q '^default '; do
                  ip route del default dev "$PRIVATE_IF" 2>/dev/null || break
                done
                SCRIPT
            },
            {
              path        = "/etc/systemd/system/infrafactory-ovh-private-route-cleanup.service"
              permissions = "0644"
              owner       = "root:root"
              content     = <<-UNIT
                [Unit]
                Description=Remove OVH private NIC default route
                After=network-online.target
                Wants=network-online.target

                [Service]
                Type=oneshot
                ExecStart=/usr/local/sbin/infrafactory-ovh-private-route-cleanup
                UNIT
            },
            {
              path        = "/etc/systemd/system/infrafactory-ovh-private-route-cleanup.timer"
              permissions = "0644"
              owner       = "root:root"
              content     = <<-UNIT
                [Unit]
                Description=Periodically remove OVH private NIC default route

                [Timer]
                OnBootSec=30s
                OnUnitActiveSec=1min
                AccuracySec=10s

                [Install]
                WantedBy=timers.target
                UNIT
            },
          ]
        )

        bootcmd = [
          <<-EOT
            PRIVATE_IP="${local.all_vms_map[name].private_ip}"
            PRIVATE_IF="$(ip -o -4 addr show | awk -v ip="$PRIVATE_IP" '$4 ~ "^" ip "/" {print $2; exit}')"
            if [ -n "$PRIVATE_IF" ]; then
              while ip route show default dev "$PRIVATE_IF" | grep -q '^default '; do
                ip route del default dev "$PRIVATE_IF" 2>/dev/null || break
              done
            fi
          EOT
        ]

        runcmd = concat(
          [
            ["/usr/local/sbin/infrafactory-ovh-private-route-cleanup"],
            ["systemctl", "daemon-reload"],
            ["systemctl", "enable", "--now", "infrafactory-ovh-private-route-cleanup.timer"],
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

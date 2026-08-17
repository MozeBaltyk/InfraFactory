###
### Contract: cloudinit-renderer (§11 — variant selection + per-node rendering).
###
### Plan tests: rendered user-data is a pure template render, assertable without
### creating resources.
###

run "renders_per_node_with_selected_variant" {
  command = plan

  variables {
    cloud_init_selected = "rke2"
    cluster_token       = "contract-token"
    vms = {
      node1 = {
        hostname           = "node1"
        fqdn               = "node1.lab.internal"
        domain             = "lab.internal"
        node_role          = "controller"
        is_first_master    = true
        first_master_ip    = "10.0.0.1"
        current_private_ip = "10.0.0.1"
        extra_disks        = []
        k3s_tls_sans       = []
        rke2_tls_sans      = []
      }
    }
  }

  assert {
    condition     = can(output.rendered_cloudinit["node1"])
    error_message = "rendered map must contain an entry per VM name"
  }

  assert {
    condition     = can(regex("hostname: node1", output.rendered_cloudinit["node1"]))
    error_message = "rendered user-data must carry the node hostname"
  }

  assert {
    condition     = can(regex("fqdn: node1\\.lab\\.internal", output.rendered_cloudinit["node1"]))
    error_message = "rendered user-data must carry the node FQDN"
  }

  assert {
    condition     = can(regex("/etc/rancher/rke2/config\\.yaml", output.rendered_cloudinit["node1"]))
    error_message = "rke2 variant must render the rke2 config path"
  }

  assert {
    condition     = can(regex("token: \"contract-token\"", output.rendered_cloudinit["node1"]))
    error_message = "rendered user-data must carry the cluster token"
  }
}

run "k3s_variant_renders_k3s_config" {
  command = plan

  variables {
    cloud_init_selected = "k3s"
    cluster_token       = "contract-token"
    vms = {
      node1 = {
        hostname           = "node1"
        fqdn               = "node1.lab.internal"
        domain             = "lab.internal"
        node_role          = "controller"
        is_first_master    = true
        first_master_ip    = "10.0.0.1"
        current_private_ip = "10.0.0.1"
        extra_disks        = []
        k3s_tls_sans       = []
        rke2_tls_sans      = []
      }
    }
  }

  assert {
    condition     = can(regex("/etc/rancher/k3s/config\\.yaml", output.rendered_cloudinit["node1"]))
    error_message = "k3s variant must render the k3s config path"
  }
}

run "default_variant_skips_cluster_config" {
  command = plan

  variables {
    cloud_init_selected = "default"
    cluster_token       = "contract-token"
    vms = {
      infra1 = {
        hostname           = "infra1"
        fqdn               = "infra1.lab.internal"
        domain             = "lab.internal"
        node_role          = "infra"
        is_first_master    = false
        first_master_ip    = null
        current_private_ip = "10.0.0.5"
        extra_disks        = []
        k3s_tls_sans       = []
        rke2_tls_sans      = []
      }
    }
  }

  assert {
    condition     = !can(regex("/etc/rancher/(k3s|rke2)/config\\.yaml", output.rendered_cloudinit["infra1"]))
    error_message = "default variant must not render any cluster join config"
  }

  assert {
    condition     = can(regex("hostname: infra1", output.rendered_cloudinit["infra1"]))
    error_message = "default variant must still render per-node basics (hostname)"
  }
}

run "per_vm_variant_override_wins" {
  command = plan

  variables {
    cloud_init_selected = "k3s"
    cluster_token       = "contract-token"
    vms = {
      node1 = {
        hostname            = "node1"
        fqdn                = "node1.lab.internal"
        domain              = "lab.internal"
        node_role           = "controller"
        is_first_master     = true
        first_master_ip     = "10.0.0.1"
        current_private_ip  = "10.0.0.1"
        extra_disks         = []
        k3s_tls_sans        = []
        rke2_tls_sans       = []
        cloud_init_selected = "default"
      }
    }
  }

  assert {
    condition     = !can(regex("/etc/rancher/(k3s|rke2)/config\\.yaml", output.rendered_cloudinit["node1"]))
    error_message = "per-VM cloud_init_selected override must win over the shared variant"
  }
}
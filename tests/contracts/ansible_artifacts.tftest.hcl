###
### Contract: ansible-artifacts (§11 — normalized node model + SSH transport).
###
### Plan tests: hosts.ini groups and ansible.cfg transport are pure template
### renders, assertable without creating resources.
###

run "inventory_normalizes_nodes_into_groups" {
  command = plan

  variables {
    controller_ips = ["10.0.0.1", "10.0.0.2"]
    worker_ips     = ["10.0.0.3"]
    vm_ips         = ["10.0.0.4"]
  }

  assert {
    condition     = can(regex("\\[CONTROLLERS\\]", output.gitops_hosts_ini))
    error_message = "inventory must contain a CONTROLLERS group"
  }

  assert {
    condition     = can(regex("\\[WORKERS\\]", output.gitops_hosts_ini))
    error_message = "inventory must contain a WORKERS group"
  }

  assert {
    condition     = can(regex("\\[VMS\\]", output.gitops_hosts_ini))
    error_message = "inventory must contain a VMS group"
  }

  assert {
    condition     = can(regex("\\[K8S_CLUSTER:children\\]", output.gitops_hosts_ini))
    error_message = "inventory must contain a K8S_CLUSTER children group"
  }

  assert {
    condition     = can(regex("controller1 ansible_host=10\\.0\\.0\\.1", output.gitops_hosts_ini))
    error_message = "controller1 must map to the first controller IP"
  }

  assert {
    condition     = can(regex("controller2 ansible_host=10\\.0\\.0\\.2", output.gitops_hosts_ini))
    error_message = "controller2 must map to the second controller IP"
  }

  assert {
    condition     = can(regex("worker1 ansible_host=10\\.0\\.0\\.3", output.gitops_hosts_ini))
    error_message = "worker1 must map to the first worker IP"
  }

  assert {
    condition     = can(regex("vm1 ansible_host=10\\.0\\.0\\.4", output.gitops_hosts_ini))
    error_message = "vm1 must map to the first VM IP"
  }
}

run "ansible_cfg_direct_transport_without_jump" {
  command = plan

  variables {
    proxy_jump = null
  }

  assert {
    condition     = !can(regex("\\[ssh_connection\\]", output.gitops_ansible_cfg))
    error_message = "ansible.cfg must not configure a jump host when proxy_jump is null"
  }

  assert {
    condition     = can(regex("remote_user = ubuntu", output.gitops_ansible_cfg))
    error_message = "ansible.cfg must set remote_user"
  }
}

run "ansible_cfg_jump_transport_with_proxy" {
  command = plan

  variables {
    proxy_jump = {
      common_args = "-J bastion@10.9.9.9"
    }
  }

  assert {
    condition     = can(regex("\\[ssh_connection\\]", output.gitops_ansible_cfg))
    error_message = "ansible.cfg must configure ssh_connection when proxy_jump is set"
  }

  assert {
    condition     = can(regex("ssh_common_args = -J bastion@10\\.9\\.9\\.9", output.gitops_ansible_cfg))
    error_message = "ansible.cfg must carry the proxy jump common args"
  }
}
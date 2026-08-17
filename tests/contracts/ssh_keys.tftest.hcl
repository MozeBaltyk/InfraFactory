###
### Contract: ssh-keys (§11 — secrets module).
###
### Apply test (local providers only): a real RSA key pair must be generated and
### exposed via the gitops outputs.
###

run "ssh_keys_generates_rsa_keypair" {
  command = apply

  assert {
    condition     = startswith(output.ssh_private_key_pem, "-----BEGIN RSA PRIVATE KEY-----")
    error_message = "private_key_pem must be a PEM-encoded RSA private key"
  }

  assert {
    condition     = startswith(output.ssh_public_key_openssh, "ssh-rsa ")
    error_message = "public_key_openssh must be an OpenSSH RSA public key"
  }

  assert {
    condition     = length(output.ssh_cluster_token) == 32
    error_message = "cluster_token must be 32 characters (random fallback)"
  }
}

run "ssh_keys_explicit_token_is_kept" {
  command = apply

  variables {
    k3s_token = "explicit-token-value"
  }

  assert {
    condition     = output.ssh_cluster_token == "explicit-token-value"
    error_message = "explicit k3s_token must be kept, not replaced by the random fallback"
  }
}

run "ssh_keys_rke2_token_selected" {
  command = apply

  variables {
    cloud_init_selected = "rke2"
    rke2_token          = "rke2-token-value"
  }

  assert {
    condition     = output.ssh_cluster_token == "rke2-token-value"
    error_message = "rke2_token must win when cloud_init_selected is rke2"
  }
}
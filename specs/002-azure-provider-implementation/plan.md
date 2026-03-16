# Implementation Plan: Azure Provider Implementation

## Tech Stack

- **Infrastructure as Code**: OpenTofu (fork of Terraform)
- **Cloud Provider**: Azure Resource Manager (azurerm provider)
- **Bootstrap**: cloud-init (shared templates from providers/shared/cloud-init/)
- **Configuration Management**: Ansible (inventory generated from OpenTofu outputs)
- **Orchestration**: Just (for CLI workflows)

## Libraries & Dependencies

- OpenTofu azurerm provider (latest version)
- Shared cloud-init templates (k3s, rke2, default)
- Ansible roles from providers/shared/ansible/roles/

## Project Structure

The Azure provider will follow the same structure as Libvirt:

```
providers/azure/
├── keys.tf          # SSH key generation and management
├── main.tf          # Core infrastructure provisioning (VMs, networking)
├── variables.tf     # Input variables (cluster config, VM specs)
├── output.tf        # Output values (IPs, inventory data)
├── providers.tf     # Provider configuration
└── templates.tf     # Cloud-init template rendering
```

## Implementation Strategy

1. **Provider Setup**: Configure azurerm provider with authentication
2. **Variables**: Define all required variables matching Libvirt structure
3. **Keys**: Implement SSH key generation
4. **Infrastructure**: Create VMs, networking, security groups
5. **Cloud-init**: Integrate shared templates
6. **Outputs**: Generate Ansible inventory
7. **Testing**: Validate end-to-end functionality

## Dependencies

- Must complete after Libvirt provider is stable
- Uses shared cloud-init templates
- Follows established provider conventions

## Success Criteria

- Azure provider supports N masters + N workers
- Cloud-init bootstrap works consistently
- Ansible inventory is generated correctly
- End-to-end provisioning succeeds
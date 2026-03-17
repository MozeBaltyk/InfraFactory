# Feature Specification: Azure Provider Implementation

**Feature Branch**: 002-azure-provider-implementation  
**Created**: March 16, 2026  
**Status**: Draft  
**Input**: User description: "Create a feature specification for implementing the Azure provider in InfraFactory. The feature should follow the established Libvirt pattern: support N masters and N workers, use cloud-init for bootstrap, generate Ansible inventory. Include user stories for each major component (variables, keys, main provisioning, templates, outputs, testing). Set priorities based on dependency order."

## Clarifications

### Session 2026-03-17 (Extended)
- Q: What are the maximum cluster scale limits for masters and workers? → A: Small - Support up to 3 masters and 10 workers per cluster
- Q: Which authentication methods should be supported for VM access? → A: SSH Keys - SSH key-based authentication only
- Q: How should deployment failures be handled and recovered? → A: Manual - Manual intervention required for failed deployments
- Q: Which external dependencies and failure modes need explicit handling? → A: Image Availability, Network Access, Quotas
- Q: What is the resource lifecycle and cleanup strategy? → A: Persistent - Resources persist until explicitly destroyed
- Q: What specific network security group rules should be implemented? → A: Allow SSH and port 6443 from my computer to connect via SSH to VMs and Kubernetes cluster API
- Q: What specific error handling strategies should be implemented for Azure quota limits being reached? → A: Display clear error message that the quota is reached
- Q: How should the system handle cases where Ubuntu 24.04 LTS images are not available in the selected Azure region? → A: Display clear error
- Q: What should happen when network connectivity to Azure services is interrupted during provisioning? → A: Try refresh and deploy again
- Q: How should partial provisioning failures be handled (e.g., some VMs succeed, others fail)? → A: Refresh state and deploy again
- Q: What recovery procedures should be implemented when cloud-init fails on individual VMs? → A: Nothing (no specific automated recovery)
- Q: What specific manual recovery steps should be documented for deployment failures? → A: Nothing, give a status of the deployment
- Q: Should validation tasks be added for non-functional requirements in the implementation plan? → A: Yes

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Configure Azure Provider Variables (Priority: P1)

As an infrastructure engineer, I want to configure Azure provider variables that match the Libvirt pattern so that I can consistently define cluster topology, infrastructure specs, and cloud-init settings across providers.

**Why this priority**: Variables are the foundation that all other components depend on - they define the cluster structure and must be established first.

**Independent Test**: Can be tested by validating that all required variables are defined and terraform plan succeeds without errors.

**Acceptance Scenarios**:

1. **Given** Azure provider variables.tf, **When** terraform plan is run, **Then** all variables are properly defined with appropriate defaults matching Libvirt structure
2. **Given** cluster topology variables, **When** masters=3 and workers=2 are specified, **Then** the configuration supports scalable cluster sizing
3. **Given** OS catalog variables, **When** ubuntu24 is selected, **Then** Azure-compatible image references are used

---

### User Story 2 - Implement SSH Key Management (Priority: P2)

As an infrastructure engineer, I want SSH keys to be automatically generated and managed for Azure VMs so that secure access is established during provisioning.

**Why this priority**: SSH keys are required for cloud-init bootstrap and remote-exec provisioners, and must be available before VM creation.

**Independent Test**: Can be tested by verifying SSH key files are created in the environment directory and can be used for authentication.

**Acceptance Scenarios**:

1. **Given** keys.tf implementation, **When** terraform apply runs, **Then** RSA key pair is generated and saved to local files
2. **Given** generated public key, **When** injected into Azure VMs, **Then** SSH access works using the private key
3. **Given** environment directory, **When** keys are created, **Then** proper file permissions are set (0600 for private key)

---

### User Story 3 - Provision Azure Infrastructure (Priority: P3)

As an infrastructure engineer, I want Azure VMs and networking to be provisioned following the Libvirt pattern so that N masters and N workers are created with proper network configuration.

**Why this priority**: Core infrastructure provisioning is the main functionality that depends on variables and keys being in place.

**Independent Test**: Can be tested by verifying Azure resources are created and VMs are accessible via SSH.

**Acceptance Scenarios**:

1. **Given** cluster.masters=1 and cluster.workers=0, **When** terraform apply completes, **Then** 1 controller VM and 0 worker VMs are created in Azure
2. **Given** Azure network configuration, **When** VMs are provisioned, **Then** public IPs are assigned and NSG allows SSH and port 6443 from my computer
3. **Given** VM specifications, **When** infra.memory_mb and infra.cpu are set, **Then** Azure instance size matches the specifications

---

### User Story 4 - Integrate Cloud-init Bootstrap (Priority: P4)

As an infrastructure engineer, I want cloud-init to bootstrap Azure VMs using shared templates so that VMs are initialized consistently with hostname, SSH keys, and cluster configuration.

**Why this priority**: Cloud-init runs during VM creation and must be configured before VMs are fully provisioned.

**Independent Test**: Can be tested by verifying cloud-init status completes successfully and VM has expected configuration.

**Acceptance Scenarios**:

1. **Given** shared cloud-init templates, **When** Azure VMs boot, **Then** cloud-init applies hostname, domain, and SSH key configuration
2. **Given** cluster.cloud_init_selected="k3s", **When** VMs initialize, **Then** K3s-specific configuration is applied from templates
3. **Given** master/worker roles, **When** cloud-init runs, **Then** appropriate node roles are configured for Kubernetes clustering

---

### User Story 5 - Generate Ansible Inventory (Priority: P5)

As an infrastructure engineer, I want Ansible inventory to be automatically generated from Azure VM outputs so that post-provisioning configuration can be applied using the shared inventory template.

**Why this priority**: Inventory generation depends on VMs being created and having IP addresses assigned.

**Independent Test**: Can be tested by verifying hosts.ini file is created with correct IP mappings for controllers and workers.

**Acceptance Scenarios**:

1. **Given** Azure VM public IPs, **When** terraform apply completes, **Then** hosts.ini is generated using shared inventory template
2. **Given** controller and worker VMs, **When** inventory is created, **Then** [CONTROLLERS] and [WORKERS] sections contain correct IP addresses
3. **Given** generated inventory, **When** ansible uses it, **Then** all VMs are accessible and properly grouped

---

### User Story 6 - Validate Azure Provider Implementation (Priority: P6)

As an infrastructure engineer, I want to test the complete Azure provider implementation so that I can verify it works end-to-end following the Libvirt pattern.

**Why this priority**: Testing validates that all components work together and the implementation is complete.

**Independent Test**: Can be tested by running full provisioning cycle and verifying cluster functionality.

**Acceptance Scenarios**:

1. **Given** complete Azure provider, **When** terraform apply runs with masters=1 workers=1, **Then** full infrastructure is provisioned without errors
2. **Given** provisioned cluster, **When** Ansible runs against generated inventory, **Then** post-provisioning configuration succeeds
3. **Given** K3s cluster, **When** validation tests run, **Then** Kubernetes API is accessible and nodes are ready

### Edge Cases

- **Azure Quota Limits**: When quota limits are reached during VM provisioning, display clear error message that the quota is reached
- **Image Availability**: When Ubuntu 24.04 LTS images are not available in the selected Azure region, display clear error
- **Network Connectivity**: When network connectivity to Azure services is interrupted during provisioning, try refresh and deploy again
- **Partial Provisioning Failure**: When some VMs succeed and others fail, refresh state and deploy again
- **Cloud-init Failure**: When cloud-init fails on individual VMs, no specific automated recovery is implemented
- **Manual Recovery**: For deployment failures, provide status of the deployment (no automated recovery steps)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Azure provider MUST support configurable number of masters (N) and workers (M) matching Libvirt cluster topology
- **FR-002**: Azure provider MUST use shared cloud-init templates from providers/shared/cloud-init/ for VM bootstrap
- **FR-003**: Azure provider MUST generate Ansible inventory compatible with providers/shared/inventory/hosts.tpl
- **FR-004**: Azure provider MUST implement SSH key generation and injection following Libvirt keys.tf pattern
- **FR-005**: Azure provider MUST create Azure VMs with public IPs, network security groups allowing SSH and port 6443 from my computer, and proper sizing
- **FR-006**: Azure provider MUST support Ubuntu 24.04 LTS as the primary OS matching Libvirt os_catalog
- **FR-007**: Azure provider MUST include remote-exec provisioners to wait for cloud-init completion
- **FR-008**: Azure provider MUST output cluster node IPs in the same format as Libvirt for consistency

### Non-Functional Requirements

- **NFR-001**: Authentication MUST use SSH key-based authentication only for VM access
- **NFR-002**: Resources MUST persist until explicitly destroyed via terraform destroy
- **NFR-003**: Deployment failures MUST be handled through manual intervention

### Key Entities *(include if feature involves data)*

- **Azure Resource Group**: Contains all Azure resources for the cluster deployment
- **Virtual Network**: Provides network isolation and IP address management
- **Network Security Group**: Controls inbound/outbound traffic rules for VMs
- **Virtual Machines**: Azure Linux VMs serving as masters (controllers) and workers
- **Public IP Addresses**: External access points for each VM
- **SSH Key Pair**: Generated keys for secure VM access
- **Ansible Inventory**: Generated hosts.ini file for post-provisioning configuration

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Azure provider supports 1-3 masters and 0-10 workers without configuration changes
- **SC-002**: VMs boot and complete cloud-init within 5 minutes of creation
- **SC-003**: SSH access works immediately after cloud-init completion using generated keys
- **SC-004**: Ansible inventory is generated with correct IP mappings for all nodes
- **SC-005**: K3s cluster forms successfully when using k3s cloud-init template
- **SC-006**: Terraform apply completes without errors for standard cluster configurations
- **SC-007**: Resource cleanup works properly when terraform destroy is run

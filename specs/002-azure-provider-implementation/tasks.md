# Tasks: Azure Provider Implementation

**Input**: Design documents from `/specs/002-azure-provider-implementation/`
**Prerequisites**: plan.md (required), spec.md (required for user stories)

**Tests**: Tests are not requested in the feature specification, so none included.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Provider implementation: `providers/azure/` following Libvirt structure

## Dependencies

User stories must be completed in priority order:
- US1 (P1) → US2 (P2) → US3 (P3) → US4 (P4) → US5 (P5) → US6 (P6)

Each story builds on the previous ones, with variables depending on prior configuration.

## Implementation Strategy

**MVP First**: Start with User Story 1 (variables) as the minimum viable implementation. Each subsequent story adds incremental functionality.

**Incremental Delivery**: Complete one user story at a time, ensuring each is independently testable before moving to the next.

**Parallel Opportunities**: Within each user story, tasks marked [P] can be implemented in parallel as they work on different files.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [X] T001 Create Azure provider directory structure per implementation plan

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

No foundational tasks required - user story implementation can begin immediately after setup.

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Configure Azure Provider Variables (Priority: P1) 🎯 MVP

**Goal**: Configure Azure provider variables that match the Libvirt pattern for consistent cluster topology, infrastructure specs, and cloud-init settings.

**Independent Test**: Can be tested by validating that all required variables are defined and terraform plan succeeds without errors.

### Implementation for User Story 1

- [ ] T002 [US1] Create variables.tf with Azure authentication variables (subscription_id, client_id, client_secret, tenant_id) in providers/azure/variables.tf
- [ ] T003 [US1] Add cluster topology variables (masters up to 3, workers up to 10, domain, username) in providers/azure/variables.tf
- [ ] T004 [US1] Add infrastructure specification variables (instance_size, disk_size) in providers/azure/variables.tf
- [ ] T005 [US1] Add cloud-init selection variables (cloud_init_selected) in providers/azure/variables.tf
- [ ] T006 [US1] Add Azure-specific variables (location, resource group name) in providers/azure/variables.tf
- [ ] T007 [US1] Add OS catalog variables with Azure-compatible Ubuntu 24.04 LTS image references in providers/azure/variables.tf
- [ ] T008 [US1] Add network configuration variables (cidr, ip_type) in providers/azure/variables.tf
- [ ] T009 [US1] Add K3s-specific variables (version, token, etcd_enabled, traefik_enabled, etc.) in providers/azure/variables.tf

**Checkpoint**: At this point, User Story 1 should be fully functional and terraform plan should succeed with variable validation.

---

## Phase 4: User Story 2 - Implement SSH Key Management (Priority: P2)

**Goal**: SSH keys are automatically generated and managed for Azure VMs to establish secure access during provisioning.

**Independent Test**: Can be tested by verifying SSH key files are created in the environment directory and can be used for authentication.

### Implementation for User Story 2

- [ ] T010 [US2] Create keys.tf with TLS private key resource (RSA 4096-bit) in providers/azure/keys.tf
- [ ] T011 [US2] Add local file resources for saving public and private keys in providers/azure/keys.tf
- [ ] T012 [US2] Configure proper file permissions for private key (0600) in providers/azure/keys.tf
- [ ] T013 [US2] Add environment directory creation logic in providers/azure/keys.tf

**Checkpoint**: At this point, User Story 2 should generate SSH keys that can be used for VM access.

---

## Phase 5: User Story 3 - Provision Azure Infrastructure (Priority: P3)

**Goal**: Azure VMs and networking are provisioned following the Libvirt pattern with N masters and N workers and proper network configuration.

**Independent Test**: Can be tested by verifying Azure resources are created and VMs are accessible via SSH.

### Implementation for User Story 3

- [ ] T014 [US3] Create providers.tf with azurerm provider configuration and authentication in providers/azure/providers.tf
- [ ] T015 [P] [US3] Create main.tf with resource group and virtual network in providers/azure/main.tf
- [ ] T016 [P] [US3] Add subnet configuration within virtual network in providers/azure/main.tf
- [ ] T017 [P] [US3] Add network security group with SSH and required ports in providers/azure/main.tf
- [ ] T018 [P] [US3] Associate NSG with subnet in providers/azure/main.tf
- [ ] T019 [US3] Implement master VM provisioning with public IPs (up to 3 masters) in providers/azure/main.tf
- [ ] T020 [US3] Implement worker VM provisioning with public IPs (up to 10 workers) in providers/azure/main.tf
- [ ] T021 [US3] Add remote-exec provisioners to wait for cloud-init completion on all VMs in providers/azure/main.tf

**Checkpoint**: At this point, User Story 3 should create Azure infrastructure with accessible VMs.

---

## Phase 6: User Story 4 - Integrate Cloud-init Bootstrap (Priority: P4)

**Goal**: cloud-init bootstraps Azure VMs using shared templates for consistent initialization with hostname, SSH keys, and cluster configuration.

**Independent Test**: Can be tested by verifying cloud-init status completes successfully and VM has expected configuration.

### Implementation for User Story 4

- [ ] T022 [US4] Create templates.tf with cloud-init template data source in providers/azure/templates.tf
- [ ] T023 [US4] Configure cloud-init for master nodes using shared k3s templates in providers/azure/templates.tf
- [ ] T024 [US4] Configure cloud-init for worker nodes using shared k3s templates in providers/azure/templates.tf
- [ ] T025 [US4] Add ansible.cfg generation for environment-specific configuration in providers/azure/templates.tf

**Checkpoint**: At this point, User Story 4 should bootstrap VMs with cloud-init successfully.

---

## Phase 7: User Story 5 - Generate Ansible Inventory (Priority: P5)

**Goal**: Ansible inventory is automatically generated from Azure VM outputs using the shared inventory template for post-provisioning configuration.

**Independent Test**: Can be tested by verifying hosts.ini file is created with correct IP mappings for controllers and workers.

### Implementation for User Story 5

- [ ] T026 [US5] Create output.tf with VM public IP outputs in providers/azure/output.tf
- [ ] T027 [US5] Add inventory template rendering using shared hosts.tpl in providers/azure/output.tf
- [ ] T028 [US5] Generate hosts.ini file with controller and worker sections in providers/azure/output.tf
- [ ] T029 [US5] Add kubeconfig retrieval for K3s clusters in providers/azure/output.tf

**Checkpoint**: At this point, User Story 5 should generate a valid Ansible inventory file.

---

## Phase 8: User Story 6 - Validate Azure Provider Implementation (Priority: P6)

**Goal**: Test the complete Azure provider implementation to verify it works end-to-end following the Libvirt pattern.

**Independent Test**: Can be tested by running full provisioning cycle and verifying cluster functionality.

### Implementation for User Story 6

- [ ] T030 [US6] Create test tfvars file for validation in env/AZ/test.tfvars
- [ ] T031 [US6] Run terraform plan validation with test variables
- [ ] T032 [US6] Execute terraform apply test with minimal cluster (1 master, 0 workers)
- [ ] T033 [US6] Verify generated Ansible inventory is correct
- [ ] T034 [US6] Test SSH connectivity to provisioned VMs
- [ ] T035 [US6] Validate K3s cluster formation and kubeconfig retrieval
- [ ] T036 [US6] Validate SSH-only authentication (no other auth methods allowed)
- [ ] T037 [US6] Validate persistent resource lifecycle (resources remain until destroyed)
- [ ] T038 [US6] Test deployment status reporting for manual recovery guidance

**Checkpoint**: At this point, User Story 6 should validate the complete Azure provider implementation including non-functional requirements.

---

## Final Phase: Polish & Cross-Cutting Concerns

No polish tasks required for this implementation.

---

## Parallel Execution Examples

**Per User Story**:
- **US1**: All tasks sequential (single file)
- **US3**: T015, T016, T017, T018 can run in parallel (different resources in main.tf)
- **US4**: T023 and T024 can run in parallel (different node types)
- **US6**: T031 and T033 can run in parallel (plan and inventory check)

**Cross-Story**: Stories must be completed sequentially due to dependencies, but within each story, parallel tasks can be implemented simultaneously.
# Azure Provider Requirements Quality Checklist

**Created**: 2026-03-17
**Focus**: Azure provider implementation following Libvirt pattern
**Purpose**: Validate requirements quality for N masters + N workers, cloud-init bootstrap, and Ansible inventory generation

## Requirement Completeness

- [ ] Are all required provider files specified (keys.tf, main.tf, variables.tf, output.tf, providers.tf, templates.tf)? [Completeness, Plan §Project Structure]
- [ ] Are Azure-specific variables defined (subscription_id, client_id, client_secret, tenant_id)? [Completeness, Spec §US1]
- [ ] Are cluster topology variables specified (masters, workers, domain, username)? [Completeness, Spec §US1]
- [ ] Are infrastructure variables defined (instance_size, disk_size, memory_mb, cpu)? [Completeness, Spec §US1]
- [ ] Are cloud-init selection variables included (cloud_init_selected)? [Completeness, Spec §US1]
- [ ] Are OS catalog variables specified with Azure-compatible image references? [Completeness, Spec §US1]
- [ ] Are network configuration variables defined (cidr, ip_type)? [Completeness, Spec §US1]
- [ ] Are K3s-specific variables included (version, token, etcd_enabled, etc.)? [Completeness, Spec §US1]
- [ ] Are SSH key generation requirements specified (algorithm, key size, file permissions)? [Completeness, Spec §US2]
- [ ] Are Azure resource requirements defined (resource group, virtual network, subnets, NSG)? [Completeness, Spec §US3]
- [ ] Are VM provisioning requirements specified for both masters and workers? [Completeness, Spec §US3]
- [ ] Are public IP allocation requirements defined for all VMs? [Completeness, Spec §US3]
- [ ] Are cloud-init integration requirements specified for shared templates? [Completeness, Spec §US4]
- [ ] Are remote-exec provisioners required for cloud-init status waiting? [Completeness, Spec §US4]
- [ ] Are Ansible inventory generation requirements specified using shared hosts.tpl? [Completeness, Spec §US5]
- [ ] Are kubeconfig retrieval requirements defined for K3s clusters? [Completeness, Spec §US5]
- [ ] Are test environment requirements specified (test.tfvars, validation commands)? [Completeness, Spec §US6]

## Requirement Clarity

- [ ] Is the maximum cluster scale clearly specified (3 masters, 10 workers)? [Clarity, Spec §Clarifications]
- [ ] Are authentication methods clearly defined (SSH keys only)? [Clarity, Spec §NFR-001]
- [ ] Is the resource lifecycle clearly specified (persistent until destroyed)? [Clarity, Spec §NFR-002]
- [ ] Is failure recovery approach clearly defined (manual intervention)? [Clarity, Spec §NFR-003]
- [ ] Are Azure region requirements clearly specified (location variable)? [Clarity, Spec §US1]
- [ ] Is VM sizing clearly defined (instance_size with defaults)? [Clarity, Spec §US1]
- [ ] Are OS image requirements clearly specified (Ubuntu 24.04 LTS primary)? [Clarity, Spec §FR-006]
- [ ] Is cloud-init bootstrap timing clearly specified (within 5 minutes)? [Clarity, Spec §SC-002]
- [ ] Are NSG port requirements clearly defined (SSH and required ports)? [Clarity, Spec §US3]
- [ ] Is the provider implementation priority clearly established (after Libvirt)? [Clarity, Plan §Dependencies]

## Requirement Consistency

- [ ] Do variable structures match Libvirt provider conventions? [Consistency, Spec §US1]
- [ ] Are file naming conventions consistent with other providers? [Consistency, Plan §Project Structure]
- [ ] Do output formats match Libvirt provider (IP lists, inventory structure)? [Consistency, Spec §FR-008]
- [ ] Are cloud-init template usage patterns consistent with Libvirt? [Consistency, Spec §US4]
- [ ] Do SSH key management patterns match Libvirt implementation? [Consistency, Spec §US2]
- [ ] Are terraform workspace patterns consistent with Libvirt? [Consistency, Plan §Implementation Strategy]
- [ ] Do acceptance criteria formats match across all user stories? [Consistency, Spec §User Stories]

## Acceptance Criteria Quality

- [ ] Are acceptance criteria measurable and testable for each user story? [Acceptance Criteria, Spec §User Stories]
- [ ] Can terraform plan success be objectively verified for US1? [Measurability, Spec §US1]
- [ ] Can SSH key file creation and permissions be objectively verified for US2? [Measurability, Spec §US2]
- [ ] Can Azure resource creation and SSH access be objectively verified for US3? [Measurability, Spec §US3]
- [ ] Can cloud-init completion and VM configuration be objectively verified for US4? [Measurability, Spec §US4]
- [ ] Can inventory file generation and IP mappings be objectively verified for US5? [Measurability, Spec §US5]
- [ ] Can end-to-end provisioning and cluster formation be objectively verified for US6? [Measurability, Spec §US6]

## Scenario Coverage

- [ ] Are primary success scenarios covered for all 6 user stories? [Coverage, Spec §User Stories]
- [ ] Are master node provisioning scenarios specified? [Coverage, Spec §US3]
- [ ] Are worker node provisioning scenarios specified? [Coverage, Spec §US3]
- [ ] Are different cloud-init template scenarios covered (k3s, rke2, default)? [Coverage, Spec §US4]
- [ ] Are single-master scenarios covered? [Coverage, Spec §US6]
- [ ] Are multi-master scenarios covered (up to 3 masters)? [Coverage, Spec §SC-001]
- [ ] Are scenarios with workers covered (up to 10 workers)? [Coverage, Spec §SC-001]

## Edge Case Coverage

- [ ] Are Azure quota limit scenarios addressed? [Edge Case, Spec §Edge Cases]
- [ ] Are image availability scenarios specified for different regions? [Edge Case, Spec §Edge Cases]
- [ ] Are network connectivity failure scenarios covered? [Edge Case, Spec §Edge Cases]
- [ ] Are partial provisioning failure scenarios addressed? [Edge Case, Spec §Edge Cases]
- [ ] Are cloud-init failure scenarios specified for individual VMs? [Edge Case, Spec §Edge Cases]
- [ ] Are scenarios with zero workers covered? [Edge Case, Spec §SC-001]

## Non-Functional Requirements

- [ ] Are performance requirements specified (5-minute boot time)? [Non-Functional, Spec §SC-002]
- [ ] Are security requirements defined (SSH key authentication only)? [Non-Functional, Spec §NFR-001]
- [ ] Are reliability requirements specified (successful provisioning)? [Non-Functional, Spec §SC-006]
- [ ] Are resource lifecycle requirements defined (persistent)? [Non-Functional, Spec §NFR-002]
- [ ] Are failure handling requirements specified (manual recovery)? [Non-Functional, Spec §NFR-003]

## Dependencies & Assumptions

- [ ] Are external dependencies documented (Azure API, image availability, network access, quotas)? [Dependency, Spec §Clarifications]
- [ ] Is the dependency on Libvirt provider stability documented? [Dependency, Plan §Dependencies]
- [ ] Are shared resource dependencies specified (cloud-init templates, inventory template)? [Dependency, Plan §Libraries & Dependencies]
- [ ] Are Ansible role dependencies documented? [Dependency, Plan §Libraries & Dependencies]
- [ ] Is the assumption of Ubuntu 24.04 LTS availability validated? [Assumption, Spec §FR-006]

## Ambiguities & Conflicts

- [ ] Is there any conflict between scale limits and Azure resource constraints? [Conflict, Spec §SC-001]
- [ ] Are there ambiguities in "appropriate defaults" for VM sizing? [Ambiguity, Spec §US1]
- [ ] Is "proper network configuration" clearly defined? [Ambiguity, Spec §US3]
- [ ] Are there conflicts between manual recovery and automated cloud-init? [Conflict, Spec §NFR-003]
- [ ] Is the relationship between masters and workers clearly specified? [Ambiguity, Spec §US3]
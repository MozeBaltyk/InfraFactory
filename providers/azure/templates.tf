# Azure-specific template resources for VM provisioning
# 
# This file handles cloud-init and custom image provisioning for Azure VMs.
# Azure uses user_data scripts attached to VM creation instead of ISO templates.
# 
# Template variables are rendered from cloud-init/*/cloud_init.cfg.tftpl
# and passed to azurerm_linux_virtual_machine.custom_data field.

# Reserved for future Azure image/template definitions
# Following provider symmetry pattern with libvirt/templates.tf

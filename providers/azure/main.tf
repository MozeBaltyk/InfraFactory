# Azure Infrastructure Resources

###
### Project
###

# Resource group containing all resources
resource "azurerm_resource_group" "factory-project" {
  name     = var.cluster.id
  location = var.cluster.region

  tags = {
    Creator = var.cluster.id
  }
}

###
### VPC
###

# Azure virtual network space
resource "azurerm_virtual_network" "factory-project-network" {
  name                = "${var.cluster.id}-network"
  address_space       = [var.network.cidr]
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  tags = {
    Creator = var.cluster.id
  }
}

# Azure internal subnet
resource "azurerm_subnet" "factory-project-internal" {
  name                 = "factory-project-internal"
  resource_group_name  = azurerm_resource_group.factory-project.name
  virtual_network_name = azurerm_virtual_network.factory-project-network.name
  address_prefixes     =  [cidrsubnet(var.network.cidr, 4, var.network.subnet_index)]
      # cidrsubnet("192.168.100.0/24", 4, 0)  # → 192.168.100.0/28
      # cidrsubnet("192.168.100.0/24", 4, 1)  # → 192.168.100.16/28
      # cidrsubnet("192.168.100.0/24", 4, 2)  # → 192.168.100.32/28
}

###
### VMs Network
###

# Public IP for VMs
resource "azurerm_public_ip" "vm-pip" {
  for_each = local.all_vms_map
  name                = "${var.cluster.id}-vm-pip-${each.value.name}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Creator = var.cluster.id
  }
}

# Azure network interface
resource "azurerm_network_interface" "vm-interface" {
  for_each = local.all_vms_map
  name                = "${var.cluster.id}-vm-interface-${each.value.name}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  ip_configuration {
    name                          = "vm_config"
    subnet_id                     = azurerm_subnet.factory-project-internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm-pip[each.key].id
  }

  tags = {
    Creator = var.cluster.id
  }
}

# VMs
resource "azurerm_linux_virtual_machine" "vms" {
  for_each = local.all_vms_map
  name = each.value.name
  size = each.value.instance_size

  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  network_interface_ids = [
    azurerm_network_interface.vm-interface[each.key].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = each.value.disk_size
  }

  source_image_reference {
    publisher = local.os.image.publisher
    offer     = local.os.image.offer
    sku       = local.os.image.sku
    version   = local.os.image.version
  }

  computer_name  = each.value.name
  admin_username = var.cluster.username

  admin_ssh_key {
    username   = var.cluster.username
    public_key = tls_private_key.global_key.public_key_openssh
  }

  custom_data = base64encode(
    local.cloudinit[each.key]
  )

  provisioner "remote-exec" {

    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Cloud-init done'",
    ]

    connection {
      type        = "ssh"
      host        = azurerm_public_ip.vm-pip[each.key].ip_address
      user        = var.cluster.username
      private_key = tls_private_key.global_key.private_key_pem
      timeout = "5m"
    }
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.factory_project_subnet_nsg
  ]
}

###########################
# Network Security Group
###########################
resource "azurerm_network_security_group" "factory_project_nsg" {
  name                = "${var.cluster.id}-nsg"
  location            = var.cluster.region
  resource_group_name = azurerm_resource_group.factory-project.name

  dynamic "security_rule" {
    for_each = var.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = 100 + tonumber(index(sort(keys(var.nsg_rules)), security_rule.key))
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.my_public_ip
      source_port_range          = "*"  
      destination_address_prefix = "*"
      destination_port_range     = tostring(security_rule.value.port)
    }
  }

  tags = {
    Creator = var.cluster.id
  }
}

resource "azurerm_subnet_network_security_group_association" "factory_project_subnet_nsg" {
  subnet_id                 = azurerm_subnet.factory-project-internal.id
  network_security_group_id = azurerm_network_security_group.factory_project_nsg.id
}

###########################
# DNS Zone
###########################
resource "azurerm_private_dns_zone" "factory" {
  name                = "${local.subdomain}"
  resource_group_name = azurerm_resource_group.factory-project.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "factory_link" {
  name                  = "${var.cluster.id}-link"
  resource_group_name   = azurerm_resource_group.factory-project.name
  private_dns_zone_name = azurerm_private_dns_zone.factory.name
  virtual_network_id    = azurerm_virtual_network.factory-project-network.id
}

resource "azurerm_private_dns_a_record" "private_dns" {
  for_each = local.all_vms_map
  name = each.value.name
  zone_name           = azurerm_private_dns_zone.factory.name
  resource_group_name = azurerm_resource_group.factory-project.name
  ttl                 = 300
  records = [
    azurerm_network_interface.vm-interface[each.key].private_ip_address
  ]
  depends_on = [
    azurerm_linux_virtual_machine.vms
  ]
}

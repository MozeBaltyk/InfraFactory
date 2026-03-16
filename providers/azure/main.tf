# Azure Infrastructure Resources

###
### Project
###

# Resource group containing all resources
resource "azurerm_resource_group" "factory-project" {
  name     = var.cluster.id
  location = var.cluster.region

  tags = {
    Creator = "${var.cluster.id}"
  }
}

###
### VPC
###

# Azure virtual network space
resource "azurerm_virtual_network" "factory-project-network" {
  name                = "${var.cluster.id}-network"
  address_space       = ["${var.network.cidr}"]
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  tags = {
    Creator = "${var.cluster.id}"
  }
}

# Azure internal subnet
resource "azurerm_subnet" "factory-project-internal" {
  name                 = "factory-project-internal"
  resource_group_name  = azurerm_resource_group.factory-project.name
  virtual_network_name = azurerm_virtual_network.factory-project-network.name
  address_prefixes     = ["${var.network.cidr}"]
}

### Controller

# Public IP for controller
resource "azurerm_public_ip" "controller-pip" {
  count               = var.cluster.masters
  name                = "${var.cluster.id}-controller-pip${count.index}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Creator = "${var.cluster.id}"
  }
}

# Azure network interface
resource "azurerm_network_interface" "controller-interfaces" {
  count                = var.cluster.masters
  name                = "${var.cluster.id}-controller-interface${count.index}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  ip_configuration {
    name                          = "controller_config"
    subnet_id                     = azurerm_subnet.factory-project-internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.controller-pip[count.index].id
  }

  tags = {
    Creator = "${var.cluster.id}"
  }
}

# Master VMs
resource "azurerm_linux_virtual_machine" "masters" {

  count = var.cluster.masters

  name = "${local.master_details[count.index].name}"

  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  network_interface_ids = [
    azurerm_network_interface.controller-interfaces[count.index].id
  ]

  size = var.infra.instance_size

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.infra.disk_size
  }

  source_image_reference {
    publisher = local.os.image.publisher
    offer     = local.os.image.offer
    sku       = local.os.image.sku
    version   = local.os.image.version
  }

  computer_name  = local.master_details[count.index].name
  admin_username = var.cluster.username

  admin_ssh_key {
    username   = var.cluster.username
    public_key = tls_private_key.global_key.public_key_openssh
  }

  custom_data = base64encode(
    local.cloudinit[local.master_details[count.index].name]
  )
}

### Workers

# Public IP for workers
resource "azurerm_public_ip" "worker-pip" {
  count                = var.cluster.workers
  name                = "${var.cluster.id}-worker-pip${count.index}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Creator = "${var.cluster.id}"
  }
}

# Azure network interface for workers
resource "azurerm_network_interface" "worker-interfaces" {
  count                = var.cluster.workers
  name                = "${var.cluster.id}-worker-interface${count.index}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  ip_configuration {
    name                          = "worker_config"
    subnet_id                     = azurerm_subnet.factory-project-internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.worker-pip[count.index].id
  }

  tags = {
    Creator = "${var.cluster.id}"
  }
}

# Worker VMs
resource "azurerm_linux_virtual_machine" "workers" {
  count               = var.cluster.workers
  name                = "${local.worker_details[count.index].name}"
  location            = azurerm_resource_group.factory-project.location
  resource_group_name = azurerm_resource_group.factory-project.name

  network_interface_ids = [azurerm_network_interface.worker-interfaces[count.index].id]

  size = coalesce(var.infra.instance_size, local.os.default_instance_size)

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.infra.disk_size
  }

  source_image_reference {
    publisher = local.os.image.publisher
    offer     = local.os.image.offer
    sku       = local.os.image.sku
    version   = local.os.image.version
  }

  computer_name  = "${var.cluster.id}-worker-${count.index}"
  admin_username = var.cluster.username

  admin_ssh_key {
    username   = var.cluster.username
    public_key = tls_private_key.global_key.public_key_openssh
  }

  custom_data = base64encode(
    local.cloudinit[local.worker_details[count.index].name]
  )
}

# Network Security Group
resource "azurerm_network_security_group" "factory_project_nsg" {
  name                = "${var.cluster.id}-nsg"
  location            = var.cluster.region
  resource_group_name = azurerm_resource_group.factory-project.name

  dynamic "security_rule" {
    for_each = var.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = 100 + index(keys(var.nsg_rules), security_rule.key)
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.my_public_ip
      source_port_range          = "*"  
      destination_address_prefix = "*"
      destination_port_range     = security_rule.value.port
    }
  }

  tags = {
    Creator = var.cluster.id
  }
}

###########################
# Associate NSG to subnet
###########################
resource "azurerm_subnet_network_security_group_association" "factory_project_subnet_nsg" {
  subnet_id                 = azurerm_subnet.factory-project-internal.id
  network_security_group_id = azurerm_network_security_group.factory_project_nsg.id
}
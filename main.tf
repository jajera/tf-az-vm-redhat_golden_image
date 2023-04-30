locals {
  admin_username = "devops"
  admin_password = "utq9MuyMUj2pb5un"
  my_internet_ip = "20.205.237.39"
}

data "azurerm_subscriptions" "current" {}

# Create a resource group
resource "azurerm_resource_group" "example" {
  name     = "redhat_vm_image_demo"
  location = "Southeast Asia"
  tags = {
    use_case = "redhat_vm_image_demo"
    email    = "demo@test.local"
  }
}

# Create a virtual network
resource "azurerm_virtual_network" "example" {
  name                = "vnet1"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  address_space       = ["10.0.0.0/16"]
}

# Create a subnet
resource "azurerm_subnet" "example" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Associate nsg to to vm subnet
resource "azurerm_subnet_network_security_group_association" "example" {
  subnet_id                 = azurerm_subnet.example.id
  network_security_group_id = azurerm_network_security_group.example.id
}

# Create vm public ip
resource "azurerm_public_ip" "example" {
  name                = "pip1"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = azurerm_resource_group.example.tags
}

# Create a network interface
resource "azurerm_network_interface" "example" {
  name                = "nic1"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name

  ip_configuration {
    name                          = "config"
    subnet_id                     = azurerm_subnet.example.id
    private_ip_address_allocation = "Dynamic"

    public_ip_address_id = azurerm_public_ip.example.id
  }
}

# Create a network security group
resource "azurerm_network_security_group" "example" {
  name                = "nsg1"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name

  security_rule = [
    {
      access                                     = "Allow"
      description                                = ""
      destination_address_prefix                 = "*"
      destination_address_prefixes               = []
      destination_application_security_group_ids = []
      destination_port_range                     = "22"
      destination_port_ranges                    = []
      direction                                  = "Inbound"
      name                                       = "SSH-In"
      priority                                   = 1010
      protocol                                   = "Tcp"
      source_address_prefix                      = local.my_internet_ip
      source_address_prefixes                    = []
      source_application_security_group_ids      = []
      source_port_range                          = "*"
      source_port_ranges                         = []
    }
  ]

  tags = azurerm_resource_group.example.tags
}

# Create a virtual machine
resource "azurerm_linux_virtual_machine" "example" {
  name                  = "rhel-86-gen2-gitlab"
  location              = azurerm_resource_group.example.location
  resource_group_name   = azurerm_resource_group.example.name
  size                  = "Standard_D2s_v3"
  admin_username        = local.admin_username
  admin_password        = local.admin_password
  network_interface_ids = [azurerm_network_interface.example.id]
  os_disk {
    caching                   = "ReadWrite"
    storage_account_type      = "Premium_LRS"
    write_accelerator_enabled = false
  }
  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "86-gen2"
    version   = "latest"
  }

  disable_password_authentication = false

  tags = azurerm_resource_group.example.tags
}

# Extend /dev/mapper/rootvg-rootlv partition
resource "null_resource" "extend_rootvg_rootlv" {
  connection {
    type     = "ssh"
    user     = local.admin_username
    password = local.admin_password
    host     = azurerm_public_ip.example.ip_address
  }

  provisioner "remote-exec" {
    inline = [
      "sudo lvextend -L +20G --resizefs /dev/mapper/rootvg-rootlv"
    ]
  }

  depends_on = [
    azurerm_linux_virtual_machine.example
  ]
}

# Update and install required apps
resource "null_resource" "install_and_update" {
  # triggers = {
  #   always_run = "${timestamp()}"
  # }

  connection {
    type     = "ssh"
    user     = local.admin_username
    password = local.admin_password
    host     = azurerm_public_ip.example.ip_address
  }

  provisioner "remote-exec" {
    inline = [
      "GITLAB_EE_PASSWORD=\"${local.admin_password}\"",
      "sudo yum update -y",
      "sudo yum install -y git sshpass make gcc openssl-devel bzip2-devel libffi-devel perl python39 ca-certificates",
      "curl -s https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.rpm.sh | sudo bash",
      "sudo GITLAB_ROOT_PASSWORD=\"$GITLAB_EE_PASSWORD\" dnf install -y gitlab-ee",
      "sudo yum update -y",
      "sudo yum clean all"
    ]
  }

  depends_on = [
    null_resource.extend_rootvg_rootlv
  ]
}

# Generalize vm
resource "azurerm_virtual_machine_extension" "vmimage_generalize" {
  name                       = "Microsoft.OSTCExtensions"
  virtual_machine_id         = azurerm_linux_virtual_machine.example.id
  publisher                  = "Microsoft.OSTCExtensions"
  type                       = "VMAccessForLinux"
  type_handler_version       = "1.5"
  auto_upgrade_minor_version = true

  settings = <<SETTINGS
    {
      "commandToExecute": "sudo waagent -deprovision+user && export HISTSIZE=0 && sync"
    }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "deleteOutputs": true
    }
  PROTECTED_SETTINGS

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    null_resource.install_and_update
  ]
}

# Generalize vm
resource "null_resource" "generalize_vm" {

  provisioner "local-exec" {
    command = <<-EOT
      az vm deallocate --ids ${azurerm_linux_virtual_machine.example.id}
      az vm generalize --ids ${azurerm_linux_virtual_machine.example.id}
    EOT
  }

  depends_on = [
    azurerm_virtual_machine_extension.vmimage_generalize
  ]
}

# Create an image from the generalized vm
resource "azurerm_image" "example" {
  name                      = "rhel-86-gen2-gitlab"
  location                  = azurerm_resource_group.example.location
  resource_group_name       = azurerm_resource_group.example.name
  hyper_v_generation        = "V2"
  source_virtual_machine_id = azurerm_linux_virtual_machine.example.id

  tags = azurerm_resource_group.example.tags

  depends_on = [
    null_resource.generalize_vm
  ]
}

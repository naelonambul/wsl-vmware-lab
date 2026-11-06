terraform {
  required_version = ">= 1.0.0"

  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "2.0.1"
    }
  }
}

provider "vmworkstation" {
  endpoint = var.vmrest_endpoint
  username = var.vmrest_username
  password = var.vmrest_password
  https    = false
  debug    = "NONE"
}

data "vmworkstation_virtual_machine" "ubuntu_base" {
  denomination = var.base_name
}

resource "vmworkstation_virtual_machine" "ubuntu_demo" {
  sourceid     = data.vmworkstation_virtual_machine.ubuntu_base.id
  denomination = var.clone_name
  description  = "Ubuntu 24.04 base template for Terraform"
  path         = var.clone_vmx_path
  processors   = var.clone_processors
  memory       = var.clone_memory_mb
  state        = var.power_state
}

output "ubuntu_demo_id" {
  value = vmworkstation_virtual_machine.ubuntu_demo.id
}

resource "terraform_data" "guest_bootstrap" {
  triggers_replace = [vmworkstation_virtual_machine.ubuntu_demo.id]
  provisioner "local-exec" {
    command = "bash ../bootstrap-guest.sh"
    environment = {
      VMX_WIN = vmworkstation_virtual_machine.ubuntu_demo.path
      VM_ID   = vmworkstation_virtual_machine.ubuntu_demo.id
    }
  }
}

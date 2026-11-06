terraform {
  required_version = ">= 1.3.0"

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

data "vmworkstation_virtual_machine" "base" {
  denomination = var.base_name
}

# One clone per entry of var.vms (key = VM name), each in
# <vm_root_win>\<name>\<name>.vmx. Add, change or remove entries in vms.tfvars.
resource "vmworkstation_virtual_machine" "vm" {
  for_each = var.vms

  sourceid     = data.vmworkstation_virtual_machine.base.id
  denomination = each.key
  # The provider does not set a clone's description; it reports the base VM's,
  # so any other value makes Terraform fail with "inconsistent result after apply".
  description = data.vmworkstation_virtual_machine.base.description
  path        = "${var.vm_root_win}\\${each.key}\\${each.key}.vmx"
  processors  = each.value.processors
  memory      = each.value.memory_mb
  state       = var.power_state
}

# Runs once per new clone while it is powered off (terraform-vm.sh on handles
# the order): writes the cloud-init seed and the management NIC.
resource "terraform_data" "guest_bootstrap" {
  for_each = var.vms

  triggers_replace = [vmworkstation_virtual_machine.vm[each.key].id]
  provisioner "local-exec" {
    command = "bash ../bootstrap-guest.sh"
    environment = {
      VMX_WIN = vmworkstation_virtual_machine.vm[each.key].path
      VM_ID   = vmworkstation_virtual_machine.vm[each.key].id
      VM_NAME = each.key
    }
  }
}

# Read by guest-inventory.py and check-power.sh. Built from the VMs that exist,
# so it never indexes a VM that is listed but not created yet.
output "vms" {
  value = {
    for name, vm in vmworkstation_virtual_machine.vm : name => {
      id     = vm.id
      path   = vm.path
      groups = try(var.vms[name].groups, [])
    }
  }
}

terraform {
  required_version = ">= 1.4.0" # terraform_data

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

# The provider looks the base up by display name and takes the first match.
# terraform-vm.sh checks first that exactly one VM has the name and passes its
# id (lib/config.sh lab_base_identity); stop if the lookup found another VM.
data "vmworkstation_virtual_machine" "base" {
  denomination = var.base_name

  lifecycle {
    postcondition {
      condition     = var.base_id == "" || self.id == var.base_id
      error_message = "The provider found a VM named ${var.base_name} that is not the checked base (${var.base_id}); nothing changed. Check: bash api-status.sh"
    }
  }
}

# The provider updates sourceid and path in place, and a base rebuilt at the
# same path keeps its vmrest id. Changing any of these replaces every clone
# (terraform-vm.sh on asks for --allow-destroy). Adding this to an existing
# state replaces nothing; it records the current base.
resource "terraform_data" "base_identity" {
  input = {
    id       = data.vmworkstation_virtual_machine.base.id
    path     = data.vmworkstation_virtual_machine.base.path
    prepared = var.base_prepared
  }
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

  lifecycle {
    replace_triggered_by = [terraform_data.base_identity]
    precondition {
      condition     = each.key != var.base_name
      error_message = "VM name ${each.key} is the base VM's display name; choose another name in vms.tfvars."
    }
  }
}

# Runs once per new clone while it is powered off (terraform-vm.sh on handles
# the order): writes the cloud-init seed and the management NIC. A replaced
# clone keeps its id (same path), so a base change re-runs it explicitly.
# Changes to keys or bootstrap-guest.sh do not re-run it on existing clones:
# that would need them powered off. Replace a clone to apply them.
resource "terraform_data" "guest_bootstrap" {
  for_each = var.vms

  triggers_replace = [vmworkstation_virtual_machine.vm[each.key].id]
  lifecycle {
    replace_triggered_by = [terraform_data.base_identity]
  }
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

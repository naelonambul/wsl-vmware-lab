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

locals {
  # Every VM with its image resolved; one base per image in use.
  # lan: "none", "dhcp" or the static address of the bridged NIC lan0.
  vms = { for name, spec in var.vms : name => merge(spec, {
    image = coalesce(spec.image, var.default_image)
    lan   = spec.lan_ip != null ? spec.lan_ip : (spec.lan ? "dhcp" : "none")
  }) }
  images = toset([for spec in values(local.vms) : spec.image])
}

# The provider looks a base up by display name ("<image>-base") and takes the
# first match. lib/lifecycle.sh checks first that exactly one VM has the name
# and passes its id (lib/config.sh lab_base_identity); stop if the lookup found
# another VM.
data "vmworkstation_virtual_machine" "base" {
  for_each     = local.images
  denomination = "${each.key}-base"

  lifecycle {
    postcondition {
      condition     = !contains(keys(var.bases), each.key) || self.id == try(var.bases[each.key].id, "")
      error_message = "The provider found a VM named ${each.key}-base that is not the checked base; nothing changed. Check: ./lab status"
    }
  }
}

# Per clone: its image, its LAN NIC and that base's identity. The provider updates sourceid
# and path in place, and a base rebuilt at the same path keeps its vmrest id, so
# this is what replaces a clone when its image or LAN setting changes or its
# base is rebuilt
# (lib/lifecycle.sh on asks for --allow-destroy).
resource "terraform_data" "vm_base" {
  for_each = local.vms
  # lan only when set, so VMs without a LAN NIC keep the record they had.
  input = merge({
    image    = each.value.image
    id       = data.vmworkstation_virtual_machine.base[each.value.image].id
    path     = data.vmworkstation_virtual_machine.base[each.value.image].path
    prepared = try(var.bases[each.value.image].prepared, "")
  }, { for k, v in { lan = each.value.lan } : k => v if v != "none" })
}

# One clone per entry of var.vms (key = VM name), each in
# <vm_root_win>\<name>\<name>.vmx. Add, change or remove entries in vms.tfvars.
resource "vmworkstation_virtual_machine" "vm" {
  for_each = local.vms

  sourceid     = data.vmworkstation_virtual_machine.base[each.value.image].id
  denomination = each.key
  # The provider does not set a clone's description; it reports the base VM's,
  # so any other value makes Terraform fail with "inconsistent result after apply".
  description = data.vmworkstation_virtual_machine.base[each.value.image].description
  path        = "${var.vm_root_win}\\${each.key}\\${each.key}.vmx"
  processors  = each.value.processors
  memory      = each.value.memory_mb
  state       = var.power_state

  lifecycle {
    replace_triggered_by = [terraform_data.vm_base[each.key]]
    precondition {
      condition     = !contains([for image in local.images : "${image}-base"], each.key)
      error_message = "VM name ${each.key} is a base VM's display name; choose another name in vms.tfvars."
    }
  }
}

# Runs once per new clone while it is powered off (lib/lifecycle.sh on handles
# the order): writes the cloud-init seed and the management NIC. A replaced
# clone keeps its id (same path), so a base change re-runs it explicitly.
# Changes to keys or lib/bootstrap-guest.sh do not re-run it on existing clones:
# that would need them powered off. Replace a clone to apply them.
resource "terraform_data" "guest_bootstrap" {
  for_each = local.vms

  triggers_replace = [vmworkstation_virtual_machine.vm[each.key].id]
  lifecycle {
    replace_triggered_by = [terraform_data.vm_base[each.key]]
  }
  provisioner "local-exec" {
    command = "bash ../lib/bootstrap-guest.sh"
    environment = {
      VMX_WIN = vmworkstation_virtual_machine.vm[each.key].path
      VM_ID   = vmworkstation_virtual_machine.vm[each.key].id
      VM_NAME = each.key
      VM_LAN  = each.value.lan
    }
  }
}

# Read by lib/guest-inventory.py and ./lab status. Built from the VMs that exist,
# so it never indexes a VM that is listed but not created yet.
output "vms" {
  value = {
    for name, vm in vmworkstation_virtual_machine.vm : name => {
      id     = vm.id
      path   = vm.path
      groups = try(local.vms[name].groups, [])
      image  = try(local.vms[name].image, "")
    }
  }
}

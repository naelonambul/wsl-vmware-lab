variable "vmrest_endpoint" {
  description = "VMware Workstation REST API endpoint reachable from WSL"
  type        = string
}

variable "vmrest_username" {
  description = "Username configured with vmrest.exe -C"
  type        = string
}

variable "vmrest_password" {
  description = "Password configured with vmrest.exe -C"
  type        = string
  sensitive   = true
}

variable "power_state" {
  description = "Desired VM power state"
  type        = string
  default     = "off"

  validation {
    condition     = contains(["on", "off"], var.power_state)
    error_message = "power_state must be on or off."
  }
}

# Image for VMs that do not name one (LAB_IMAGE, lib/config.sh).
variable "default_image" {
  description = "Guest image of VMs without an image in vms.tfvars"
  type        = string
  default     = "ubuntu-24.04"
}

# Set by lib/lifecycle.sh on/off (lib/config.sh lab_base_identity): for each
# image in use, the confirmed vmrest id of its base "<image>-base" and a hash of
# base/<image>/base.prepared (new with every ./lab setup --recreate). Empty
# skips the checks (destroy, diagnosis without confirmed bases).
variable "bases" {
  description = "image => { id, prepared } of the confirmed bases"
  type = map(object({
    id       = string
    prepared = string
  }))
  default = {}
}

variable "vm_root_win" {
  description = "Windows folder that holds one folder per clone, e.g. C:\\Users\\<you>\\Documents\\Virtual Machines"
  type        = string
}

# Default: one VM from LAB_CLONE_NAME/LAB_CLONE_CPUS/LAB_CLONE_MEMORY_MB (lib/config.sh).
# For a system of several VMs, write vms.tfvars in the repository root
# (template: vms.tfvars.example); lib/lifecycle.sh passes it with -var-file.
variable "vms" {
  description = "Lab VMs to create: name => { processors, memory_mb, groups (Ansible groups), image, lan, lan_ip }"
  type = map(object({
    processors = optional(number, 2)
    memory_mb  = optional(number, 2048)
    groups     = optional(list(string), ["demo"])
    image      = optional(string)      # default: var.default_image
    lan        = optional(bool, false) # bridged NIC lan0 on the physical LAN, DHCP
    lan_ip     = optional(string)      # "192.168.1.201/24": static lan0 (implies lan)
  }))

  validation {
    condition     = length(var.vms) > 0 && alltrue([for name in keys(var.vms) : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", name))])
    error_message = "vms needs at least one entry; names must be lowercase letters, digits and '-' (they become folder and host names)."
  }

  validation {
    condition = alltrue(flatten([for spec in values(var.vms) : [
      for g in spec.groups : can(regex("^[a-z_][a-z0-9_]*$", g))
    ]]))
    error_message = "Ansible group names must be lowercase letters, digits and '_' and must not start with a digit."
  }

  validation {
    condition     = alltrue([for spec in values(var.vms) : spec.image == null || contains(["ubuntu-24.04", "ubuntu-22.04", "debian-13"], coalesce(spec.image, "-"))])
    error_message = "image must be ubuntu-24.04, ubuntu-22.04 or debian-13 (lib/base.sh)."
  }

  validation {
    condition     = alltrue([for spec in values(var.vms) : spec.lan_ip == null || can(cidrhost(coalesce(spec.lan_ip, "-"), 0)) && can(regex("^[0-9.]+/[0-9]+$", coalesce(spec.lan_ip, "-")))])
    error_message = "lan_ip must be an IPv4 address with prefix, e.g. \"192.168.1.201/24\"."
  }
}

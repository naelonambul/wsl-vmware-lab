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

# Set by terraform-vm.sh from lab.env (see lib/config.sh).
variable "base_name" {
  description = "Display name of the registered base VM to clone"
  type        = string
}

variable "vm_root_win" {
  description = "Windows folder that holds one folder per clone, e.g. C:\\Users\\<you>\\Documents\\Virtual Machines"
  type        = string
}

# Default: one VM from LAB_CLONE_NAME/LAB_CLONE_CPUS/LAB_CLONE_MEMORY_MB (lib/config.sh).
# For a system of several VMs, write vms.tfvars in the repository root
# (template: vms.tfvars.example); terraform-vm.sh passes it with -var-file.
variable "vms" {
  description = "Lab VMs to create: name => { processors, memory_mb, groups (Ansible groups) }"
  type = map(object({
    processors = optional(number, 2)
    memory_mb  = optional(number, 2048)
    groups     = optional(list(string), ["demo"])
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
}

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

variable "clone_name" {
  description = "Display name of the Terraform-managed clone"
  type        = string
}

variable "clone_vmx_path" {
  description = "Windows path of the clone VMX, e.g. C:\\Users\\<you>\\Documents\\Virtual Machines\\<clone>\\<clone>.vmx"
  type        = string
}

variable "clone_processors" {
  description = "vCPU count of the clone"
  type        = number
  default     = 2
}

variable "clone_memory_mb" {
  description = "Memory of the clone in MB"
  type        = number
  default     = 2048
}

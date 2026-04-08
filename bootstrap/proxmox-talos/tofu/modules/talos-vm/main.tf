# Talos VM Module for Proxmox
# Creates a single Talos Linux VM with specified configuration

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }
}

variable "name" {
  description = "VM name"
  type        = string
}

variable "vmid" {
  description = "Proxmox VM ID"
  type        = number
}

variable "target_node" {
  description = "Proxmox node to deploy to"
  type        = string
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 50
}

variable "storage_pool" {
  description = "Proxmox storage pool for disk"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN ID (optional, set to 0 or null for no VLAN)"
  type        = number
  default     = null
}

variable "ip_address" {
  description = "Static IP address for the VM"
  type        = string
}

variable "gateway" {
  description = "Network gateway"
  type        = string
}

variable "netmask" {
  description = "Network mask in CIDR notation"
  type        = string
  default     = "24"
}

variable "iso_file" {
  description = "Path to Talos ISO on Proxmox storage"
  type        = string
}

variable "start_on_create" {
  description = "Start VM after creation"
  type        = bool
  default     = true
}

variable "qemu_guest_agent_enabled" {
  description = "Enable Proxmox QEMU Guest Agent (can cause provider waits if the guest agent isn't running)"
  type        = bool
  default     = false
}

resource "proxmox_virtual_environment_vm" "talos" {
  name      = var.name
  node_name = var.target_node
  vm_id     = var.vmid

  # Talos-specific settings
  machine = "q35"
  bios    = "seabios" # Use OVMF for SecureBoot when enabled

  # QEMU Guest Agent (Talos supports this with custom ISO)
  agent {
    enabled = var.qemu_guest_agent_enabled
    type    = "virtio"
  }

  # Boot configuration
  boot_order = ["scsi0", "ide2"]

  # CPU configuration
  cpu {
    cores   = var.cores
    sockets = 1
    type    = "host"
  }

  # Memory configuration - disable ballooning and hotplug for Talos
  memory {
    dedicated = var.memory
    floating  = 0 # Disable memory ballooning
  }

  # Disk configuration
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_size
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # CD-ROM with Talos ISO
  cdrom {
    file_id   = var.iso_file
    interface = "ide2"
  }

  # SCSI controller for better performance
  scsi_hardware = "virtio-scsi-single"

  # Network configuration
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # Serial console for Talos
  serial_device {}

  # VGA for initial setup if needed
  vga {
    type = "serial0"
  }

  # Operating system type
  operating_system {
    type = "l26" # Linux 2.6+ kernel
  }

  # Start the VM
  started = var.start_on_create

  # Lifecycle settings
  lifecycle {
    ignore_changes = [
      cdrom, # Ignore ISO changes after initial boot
    ]
  }

  # Tags for identification
  tags = ["talos", "kubernetes", "deploykube"]
}

output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.talos.vm_id
}

output "vm_name" {
  description = "VM name"
  value       = proxmox_virtual_environment_vm.talos.name
}

output "ip_address" {
  description = "Configured IP address"
  value       = var.ip_address
}

output "mac_address" {
  description = "VM MAC address"
  value       = proxmox_virtual_environment_vm.talos.network_device[0].mac_address
}

# ============================================================================
# Cluster Configuration
# ============================================================================

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "deploykube-proxmox"
}

variable "cluster_domain" {
  description = "Domain suffix for cluster services"
  type        = string
  default     = "prod.internal.example.com"
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy"
  type        = string
  default     = "1.32.3"
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.9.2"
}

# ============================================================================
# Proxmox Configuration
# ============================================================================

variable "proxmox_api_url" {
  description = "Proxmox API endpoint URL"
  type        = string
  default     = "https://198.51.100.10:8006/api2/json"
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy VMs to"
  type        = string
  default     = "pve"
}

variable "proxmox_storage" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_iso_storage" {
  description = "Proxmox storage for ISO images"
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox network bridge for VMs"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN ID for VM network (null for no VLAN)"
  type        = number
  default     = null
}

# ============================================================================
# Network Configuration
# ============================================================================

variable "network_gateway" {
  description = "Default gateway for VMs"
  type        = string
  default     = "198.51.100.1"
}

variable "network_dns" {
  description = "DNS servers for VMs (required)"
  type        = list(string)
}

variable "control_plane_vip" {
  description = "Virtual IP for Kubernetes API (Talos VIP)"
  type        = string
  default     = "198.51.100.100"
}

variable "metallb_range" {
  description = "IP range for MetalLB LoadBalancer services"
  type        = string
  default     = "198.51.100.200-198.51.100.250"
}

# ============================================================================
# Control Plane Nodes
# ============================================================================

variable "control_plane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 3
}

variable "control_plane_start_ip_suffix" {
  description = "Last octet of first control plane IP (198.51.100.X)"
  type        = number
  default     = 101
}

variable "control_plane_cores" {
  description = "CPU cores per control plane node"
  type        = number
  default     = 4
}

variable "control_plane_memory" {
  description = "Memory in MB per control plane node"
  type        = number
  default     = 8192
}

variable "control_plane_disk" {
  description = "Disk size in GB per control plane node"
  type        = number
  default     = 50
}

# ============================================================================
# Worker Nodes - Explicit definitions for heterogeneous node specs
# ============================================================================

variable "workers" {
  description = "List of worker node definitions with per-node specs"
  type = list(object({
    name      = string
    ip        = string
    cores     = number
    memory_mb = number
    disk_gb   = number
  }))
  default = []
}

# ============================================================================
# Storage Configuration
# ============================================================================

variable "nfs_server" {
  description = "NFS server IP for shared storage"
  type        = string
  default     = "198.51.100.10"
}

variable "nfs_path" {
  description = "NFS export path"
  type        = string
  default     = "/nvme01/kube"
}

# ============================================================================
# Talos ISO
# ============================================================================

variable "talos_iso_path" {
  description = "Path to Talos ISO on Proxmox storage (e.g., local:iso/talos-1.9.2-metal-amd64.iso)"
  type        = string
  default     = ""
}

# ============================================================================
# Registry Cache Configuration
# ============================================================================

variable "registry_host" {
  description = "IP or hostname of the local registry cache (Synology NAS)"
  type        = string
  default     = "198.51.100.11"
}

variable "registry_mirrors" {
  description = "Map of upstream registries to local cache ports"
  type        = map(number)
  default = {
    "docker.io"        = 5011
    "registry.example.internal" = 5012
    "quay.io"          = 5013
    "registry.k8s.io"  = 5014
    "cr.smallstep.com" = 5015
    "codeberg.org"     = 5016
    "code.forgejo.org" = 5017
  }
}

variable "registry_local_port" {
  description = "Port for local registry (bootstrap-tools and custom images)"
  type        = number
  default     = 5010
}

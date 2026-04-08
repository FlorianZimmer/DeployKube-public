# =============================================================================
# DeployKube Proxmox Talos - Main OpenTofu Configuration
# =============================================================================
#
# This configuration provisions Talos Linux VMs on Proxmox and generates
# the necessary Talos machine configurations.
#
# Prerequisites:
#   - Proxmox API token (set PM_API_TOKEN_ID and PM_API_TOKEN_SECRET env vars)
#   - Talos ISO uploaded to Proxmox (use talos_iso_path variable)
#
# Usage:
#   tofu init
#   tofu plan -var-file=../config.tfvars
#   tofu apply -var-file=../config.tfvars
# =============================================================================

provider "proxmox" {
  endpoint = var.proxmox_api_url
  insecure = true # Accept self-signed certificates

  # Authentication via environment variables:
  # PROXMOX_VE_API_TOKEN = "user@realm!tokenid=secret" (full token string)
  # OR use username/password:
  # PROXMOX_VE_USERNAME = "root@pam"
  # PROXMOX_VE_PASSWORD = "password"
}

# =============================================================================
# Local Values
# =============================================================================

locals {
  # Derive the /24 network prefix from the configured gateway (e.g. "10.50.0").
  # This keeps node IP allocation consistent with config.yaml without hard-coding a subnet.
  network_prefix = join(".", slice(split(".", var.network_gateway), 0, 3))

  # Generate control plane node configurations
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      name       = "${var.cluster_name}-cp-${i + 1}"
      vmid       = 1000 + i + 1
      ip_address = "${local.network_prefix}.${var.control_plane_start_ip_suffix + i}"
      role       = "controlplane"
    }
  ]

  # Generate worker node configurations from explicit definitions
  worker_nodes = [
    for i, w in var.workers : {
      name       = "${var.cluster_name}-${w.name}"
      vmid       = 2000 + i + 1
      ip_address = w.ip
      role       = "worker"
      cores      = w.cores
      memory     = w.memory_mb
      disk       = w.disk_gb
    }
  ]

  # All nodes combined
  all_nodes = concat(local.control_plane_nodes, local.worker_nodes)

  # The talos provider returns multi-document YAML; yamldecode() only supports a single document.
  # Split out the first document for patching and preserve the remaining documents as-is.
  talos_controlplane_docs = split("\n---\n", data.talos_machine_configuration.controlplane.machine_configuration)
  talos_worker_docs       = split("\n---\n", data.talos_machine_configuration.worker.machine_configuration)

  talos_controlplane_base = yamldecode(local.talos_controlplane_docs[0])
  talos_worker_base       = yamldecode(local.talos_worker_docs[0])

  talos_controlplane_tail = slice(local.talos_controlplane_docs, 1, length(local.talos_controlplane_docs))
  talos_worker_tail       = slice(local.talos_worker_docs, 1, length(local.talos_worker_docs))

  # Talos config schema compatibility: Talos < 1.12 does not accept HostnameConfig
  # documents when applying machine configuration.
  talos_controlplane_tail_filtered = [
    for doc in local.talos_controlplane_tail : doc
    if length(regexall("(?m)^kind:\\s*HostnameConfig\\s*$", doc)) == 0
  ]
  talos_worker_tail_filtered = [
    for doc in local.talos_worker_tail : doc
    if length(regexall("(?m)^kind:\\s*HostnameConfig\\s*$", doc)) == 0
  ]

  # Talos config schema compatibility: avoid keys that are rejected by some Talos versions
  # during bootstrap (e.g. older nodes parsing configs from newer providers).
  talos_controlplane_install_sanitized = {
    for k, v in try(local.talos_controlplane_base.machine.install, {}) : k => v
    if k != "grubUseUKICmdline"
  }
  talos_worker_install_sanitized = {
    for k, v in try(local.talos_worker_base.machine.install, {}) : k => v
    if k != "grubUseUKICmdline"
  }
}

# =============================================================================
# Control Plane VMs
# =============================================================================

module "control_plane" {
  source = "./modules/talos-vm"
  count  = var.control_plane_count

  name        = local.control_plane_nodes[count.index].name
  vmid        = local.control_plane_nodes[count.index].vmid
  target_node = var.proxmox_node

  cores        = var.control_plane_cores
  memory       = var.control_plane_memory
  disk_size    = var.control_plane_disk
  storage_pool = var.proxmox_storage

  network_bridge = var.network_bridge
  vlan_id        = var.vlan_id
  ip_address     = local.control_plane_nodes[count.index].ip_address
  gateway        = var.network_gateway

  iso_file = var.talos_iso_path
}

# =============================================================================
# Worker VMs
# =============================================================================

module "worker" {
  source = "./modules/talos-vm"
  count  = length(var.workers)

  name        = local.worker_nodes[count.index].name
  vmid        = local.worker_nodes[count.index].vmid
  target_node = var.proxmox_node

  cores        = local.worker_nodes[count.index].cores
  memory       = local.worker_nodes[count.index].memory
  disk_size    = local.worker_nodes[count.index].disk
  storage_pool = var.proxmox_storage

  network_bridge = var.network_bridge
  vlan_id        = var.vlan_id
  ip_address     = local.worker_nodes[count.index].ip_address
  gateway        = var.network_gateway

  iso_file = var.talos_iso_path
}

# =============================================================================
# Talos Machine Secrets
# =============================================================================

resource "talos_machine_secrets" "cluster" {}

# =============================================================================
# Talos Machine Configurations
# =============================================================================

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane_vip}:6443"
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets

  # NOTE: The talos provider validates config patches by reading from files, and
  # currently fails when patches are rendered via Terraform expressions.
  # Stage 0 generates these patch files before running OpenTofu.
  config_patches = ["@${path.module}/config-patches/controlplane.yaml"]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane_vip}:6443"
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets

  config_patches = ["@${path.module}/config-patches/worker.yaml"]
}

# =============================================================================
# Talos Client Configuration
# =============================================================================

data "talos_client_configuration" "cluster" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [for node in local.control_plane_nodes : node.ip_address]
  nodes                = [for node in local.all_nodes : node.ip_address]
}

# =============================================================================
# Output Talos Configurations to Files
# =============================================================================

resource "local_file" "controlplane_config" {
  count    = var.control_plane_count
  filename = "${path.module}/../talos/${local.control_plane_nodes[count.index].name}.yaml"
  content = join("\n---\n", concat(
    [
      yamlencode(merge(
        local.talos_controlplane_base,
        {
          machine = merge(
            local.talos_controlplane_base.machine,
            {
              install = local.talos_controlplane_install_sanitized
              kubelet = merge(
                try(local.talos_controlplane_base.machine.kubelet, {}),
                {
                  extraArgs = merge(
                    try(local.talos_controlplane_base.machine.kubelet.extraArgs, {}),
                    {
                      "node-ip" = local.control_plane_nodes[count.index].ip_address
                    }
                  )
                }
              )
              network = {
                hostname = local.control_plane_nodes[count.index].name
                interfaces = [merge(
                  {
                    interface = "ens18"
                    addresses = ["${local.control_plane_nodes[count.index].ip_address}/24"]
                    routes = [{
                      network = "0.0.0.0/0"
                      gateway = var.network_gateway
                    }]
                  },
                  {
                    vip = {
                      ip = var.control_plane_vip
                    }
                  }
                )]
                nameservers = var.network_dns
              }
            }
          )
        }
      ))
    ],
    local.talos_controlplane_tail_filtered,
  ))
  file_permission = "0600"
}

resource "local_file" "worker_config" {
  count    = length(var.workers)
  filename = "${path.module}/../talos/${local.worker_nodes[count.index].name}.yaml"
  content = join("\n---\n", concat(
    [
      yamlencode(merge(
        local.talos_worker_base,
        {
          machine = merge(
            local.talos_worker_base.machine,
            {
              install = local.talos_worker_install_sanitized
              kubelet = merge(
                try(local.talos_worker_base.machine.kubelet, {}),
                {
                  extraArgs = merge(
                    try(local.talos_worker_base.machine.kubelet.extraArgs, {}),
                    {
                      "node-ip" = local.worker_nodes[count.index].ip_address
                    }
                  )
                }
              )
              network = {
                hostname = local.worker_nodes[count.index].name
                interfaces = [{
                  interface = "ens18"
                  addresses = ["${local.worker_nodes[count.index].ip_address}/24"]
                  routes = [{
                    network = "0.0.0.0/0"
                    gateway = var.network_gateway
                  }]
                }]
                nameservers = var.network_dns
              }
            }
          )
        }
      ))
    ],
    local.talos_worker_tail_filtered,
  ))
  file_permission = "0600"
}

resource "local_file" "talosconfig" {
  filename        = "${path.module}/../talos/talosconfig"
  content         = data.talos_client_configuration.cluster.talos_config
  file_permission = "0600"
}

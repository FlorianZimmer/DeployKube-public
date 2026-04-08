# =============================================================================
# Outputs
# =============================================================================

output "control_plane_ips" {
  description = "IP addresses of control plane nodes"
  value       = [for node in local.control_plane_nodes : node.ip_address]
}

output "worker_ips" {
  description = "IP addresses of worker nodes"
  value       = [for node in local.worker_nodes : node.ip_address]
}

output "control_plane_vip" {
  description = "Virtual IP for Kubernetes API"
  value       = var.control_plane_vip
}

output "all_node_ips" {
  description = "All node IP addresses"
  value       = [for node in local.all_nodes : node.ip_address]
}

output "talosconfig_path" {
  description = "Path to generated talosconfig"
  value       = local_file.talosconfig.filename
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://${var.control_plane_vip}:6443"
}

output "first_control_plane_ip" {
  description = "IP of first control plane node (for bootstrap)"
  value       = local.control_plane_nodes[0].ip_address
}

output "metallb_range" {
  description = "MetalLB IP range for LoadBalancer services"
  value       = var.metallb_range
}

output "nfs_server" {
  description = "NFS server address"
  value       = var.nfs_server
}

output "nfs_path" {
  description = "NFS export path"
  value       = var.nfs_path
}

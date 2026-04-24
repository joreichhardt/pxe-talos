output "management_endpoint" {
  description = "Existing RouterOS management endpoint used by Terraform"
  value       = var.routeros_hosturl
}

output "uplink_port" {
  description = "Port carrying the upstream/native home LAN"
  value       = var.uplink_port
}

output "pi_trunk_ports" {
  description = "Ports that carry home LAN untagged and the lab VLAN tagged"
  value       = var.pi_trunk_ports
}

output "lab_access_ports" {
  description = "Ports that present the lab VLAN untagged to Talos nodes"
  value       = var.lab_access_ports
}

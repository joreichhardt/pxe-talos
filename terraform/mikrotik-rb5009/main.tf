locals {
  role_ports = concat(
    [var.uplink_port],
    var.pi_trunk_ports,
    var.lab_access_ports,
    var.home_access_ports,
    var.downstream_trunk_ports
  )

  native_home_ports = sort(distinct(concat(
    [var.uplink_port],
    var.pi_trunk_ports,
    var.downstream_trunk_ports
  )))

  tagged_lab_ports = sort(distinct(concat(
    var.pi_trunk_ports,
    var.downstream_trunk_ports
  )))

  home_access_port_map = {
    for iface in concat([var.uplink_port], var.home_access_ports) : iface => {
      comment     = "home access"
      frame_types = "admit-only-untagged-and-priority-tagged"
      pvid        = var.home_vlan_id
    }
  }

  trunk_port_map = {
    for iface in concat(var.pi_trunk_ports, var.downstream_trunk_ports) : iface => {
      comment     = "home native + lab tagged trunk"
      frame_types = "admit-all"
      pvid        = var.home_vlan_id
    }
  }

  lab_access_port_map = {
    for iface in var.lab_access_ports : iface => {
      comment     = "lab access"
      frame_types = "admit-only-untagged-and-priority-tagged"
      pvid        = var.lab_vlan_id
    }
  }

  bridge_ports = merge(
    local.home_access_port_map,
    local.trunk_port_map,
    local.lab_access_port_map
  )
}

resource "routeros_system_identity" "this" {
  name = var.identity
}

resource "routeros_interface_bridge" "this" {
  name              = var.bridge_name
  comment           = "PXE/Talos bridge for native home LAN and lab VLAN ${var.lab_vlan_id}"
  protocol_mode     = "rstp"
  ingress_filtering = true
  vlan_filtering    = true
  pvid              = var.home_vlan_id

  lifecycle {
    precondition {
      condition     = length(local.role_ports) == length(distinct(local.role_ports))
      error_message = "Port roles overlap. Each physical port may only appear once across uplink, trunk, home access and lab access."
    }
  }
}

resource "routeros_interface_bridge_port" "this" {
  for_each = local.bridge_ports

  bridge            = routeros_interface_bridge.this.name
  interface         = each.key
  comment           = each.value.comment
  frame_types       = each.value.frame_types
  ingress_filtering = true
  pvid              = each.value.pvid
}

resource "routeros_interface_bridge_vlan" "home" {
  bridge   = routeros_interface_bridge.this.name
  vlan_ids = [tostring(var.home_vlan_id)]
  untagged = sort(distinct(concat(["bridge"], local.native_home_ports)))
}

resource "routeros_interface_bridge_vlan" "lab" {
  bridge   = routeros_interface_bridge.this.name
  vlan_ids = [tostring(var.lab_vlan_id)]
  tagged   = local.tagged_lab_ports
  untagged = sort(distinct(var.lab_access_ports))
}

variable "routeros_hosturl" {
  description = "RouterOS API/REST endpoint, e.g. https://192.168.88.1 or apis://192.168.88.1:8729"
  type        = string
}

variable "routeros_username" {
  description = "RouterOS username used by Terraform"
  type        = string
}

variable "routeros_password" {
  description = "RouterOS password used by Terraform"
  type        = string
  sensitive   = true
}

variable "routeros_insecure" {
  description = "Disable TLS verification for the RouterOS API endpoint"
  type        = bool
  default     = true
}

variable "identity" {
  description = "System identity for the RB5009"
  type        = string
  default     = "rb5009-pxe"
}

variable "bridge_name" {
  description = "Name of the VLAN-aware bridge on the RB5009"
  type        = string
  default     = "bridge"
}

variable "home_vlan_id" {
  description = "Native/untagged home LAN VLAN"
  type        = number
  default     = 1
}

variable "lab_vlan_id" {
  description = "Tagged PXE/Talos lab VLAN"
  type        = number
  default     = 10
}

variable "uplink_port" {
  description = "Port connected upstream/home-side"
  type        = string
  default     = "ether1"
}

variable "pi_trunk_ports" {
  description = "Ports that carry home LAN untagged and the PXE lab VLAN tagged to the Pi or similar trunks"
  type        = list(string)
  default     = ["ether2"]
}

variable "lab_access_ports" {
  description = "Access ports for PXE/Talos nodes on the lab VLAN"
  type        = list(string)
  default     = ["ether3", "ether4", "ether5", "ether6", "ether7", "ether8"]
}

variable "home_access_ports" {
  description = "Optional untagged home-LAN access ports"
  type        = list(string)
  default     = []
}

variable "downstream_trunk_ports" {
  description = "Optional downstream trunks that carry home LAN untagged and the lab VLAN tagged"
  type        = list(string)
  default     = []
}

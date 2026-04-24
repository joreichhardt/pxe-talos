terraform {
  required_version = ">= 1.5.0"

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.99"
    }
  }
}

provider "routeros" {
  hosturl  = var.routeros_hosturl
  username = var.routeros_username
  password = var.routeros_password
  insecure = var.routeros_insecure
}

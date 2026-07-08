############################################
# Projet DBTools IaC — 3 LXC + 1 VM GitLab
############################################

variable "lxc_datastore" {
  description = "Storage Proxmox pour le rootfs des conteneurs"
  type        = string
  default     = "local-lvm"
}

locals {
  lxc_template = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
  gateway      = "192.168.1.1"
  dns_server   = "192.168.1.151"

  containers = {
    dbtools    = { vm_id = 160, ip = "192.168.1.160", mac = "BC:24:11:00:01:60" }
    mariadb    = { vm_id = 161, ip = "192.168.1.161", mac = "BC:24:11:00:01:61" }
    postgresql = { vm_id = 162, ip = "192.168.1.162", mac = "BC:24:11:00:01:62" }
  }
}

resource "proxmox_virtual_environment_container" "db" {
  for_each = local.containers

  node_name    = "pve"
  vm_id        = each.value.vm_id
  unprivileged = true
  started      = true

  initialization {
    hostname = "${each.key}.ambudot.work"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = local.gateway
      }
    }

    dns {
      servers = [local.dns_server]
    }

    user_account {
      keys = compact(split("\n", trimspace(file("${path.module}/authorized_keys.pub"))))
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.lxc_datastore
    size         = 20
  }

  network_interface {
    name        = "eth0"
    mac_address = each.value.mac
  }

  operating_system {
    template_file_id = local.lxc_template
    type             = "debian"
  }
}

output "lxc_ips" {
  value = { for k, c in local.containers : k => c.ip }
}

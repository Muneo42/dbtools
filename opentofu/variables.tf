variable "pve_endpoint" {
  description = "URL de l'API Proxmox"
  type        = string
}

variable "pve_api_token" {
  description = "Token API au format opentofu@pve!provider=SECRET"
  type        = string
  sensitive   = true
}

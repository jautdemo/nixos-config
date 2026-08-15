variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "OCI region to deploy into"
  type        = string
  default     = "eu-frankfurt-1"
}

variable "availability_domain" {
  description = "Availability domain"
  type        = string
  default     = "dead:EU-FRANKFURT-1-AD-1"
}

variable "instance_shape" {
  description = "Compute shape"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_ocpus" {
  description = "Number of OCPUs - only used for Flex shapes"
  type        = number
  default     = null
}

variable "instance_memory_gb" {
  description = "Memory in GB - only used for Flex shapes"
  type        = number
  default     = null
}

variable "image_ocid" {
  description = "Boot image OCID"
  type        = string
  default     = "ocid1.image.oc1.eu-frankfurt-1.deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef02"
}

variable "ssh_public_key_paths" {
  description = "Bootstrap-only SSH keys. RSA or standard Ed25519; OCI rejects FIDO2 sk keys."
  type        = list(string)
  default     = ["~/.ssh/id_rsa.pub"]
}

variable "boot_volume_size_gb" {
  description = "Boot volume size in GB (free tier allows up to 200 GB total)"
  type        = number
  default     = 50
}

variable "allow_public_ssh" {
  description = "Open TCP 22. Bootstrap only; re-applied false as its final step."
  type        = bool
  default     = false
}

variable "access_allowed_emails" {
  description = "Emails permitted by the Access policy"
  type        = list(string)
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}

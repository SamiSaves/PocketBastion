variable "do_token" {
  description = "DigitalOcean API token. Set via TF_VAR_do_token environment variable."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region slug. Must support block storage volumes and match the CoreOS image's region."
  type        = string
}

variable "droplet_name" {
  description = "Name for the droplet and related resources."
  type        = string
}

variable "project_name" {
  description = "Name of the DigitalOcean project that groups the droplet and state volume."
  type        = string
}

variable "droplet_size" {
  description = "Droplet size slug."
  type        = string
}

variable "coreos_image_slug" {
  description = "DigitalOcean custom image slug or ID for Fedora CoreOS."
  type        = string
  # Upload a CoreOS image to DO and paste its ID here, or use a snapshot.
  # Example: "fedora-coreos-39-20231119.3.0"
}

variable "ssh_key_name" {
  description = "Name of the SSH key registered in DigitalOcean (used for emergency console access only)."
  type        = string
}

variable "state_volume_size_gb" {
  description = "Size in GB of the persistent state volume."
  type        = number
}

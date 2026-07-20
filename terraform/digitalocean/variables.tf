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

variable "ssh_authorized_key" {
  description = "SSH PUBLIC key to register in DigitalOcean and attach to the droplet. DO requires an SSH key at creation for password-less images (CoreOS). Same key baked into Ignition; supplied from deploy.env's SSH_AUTHORIZED_KEY via TF_VAR_ssh_authorized_key (the Makefile handles this)."
  type        = string
}

variable "state_volume_size_gb" {
  description = "Size in GB of the persistent state volume."
  type        = number
}

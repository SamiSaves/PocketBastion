terraform {
  required_version = ">= 1.7"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}


# ── State volume (persistent across droplet rebuilds) ───────────────────────

resource "digitalocean_volume" "state" {
  region                   = var.region
  name                     = "${var.droplet_name}-state"
  size                     = var.state_volume_size_gb
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = "state"
  description              = "Persistent state for ${var.droplet_name}"

  lifecycle {
    prevent_destroy = true
  }
}

# ── SSH key (DO requires one at creation for password-less CoreOS images) ────
# Same public key baked into Ignition; supplied via TF_VAR_ssh_authorized_key
# (the Makefile sources it from deploy.env's SSH_AUTHORIZED_KEY).

resource "digitalocean_ssh_key" "core" {
  name       = "${var.droplet_name}-key"
  public_key = var.ssh_authorized_key
}

# ── Droplet ────────────────────────────────────────────────────────

resource "digitalocean_droplet" "server" {
  name      = var.droplet_name
  region    = var.region
  size      = var.droplet_size
  image     = var.coreos_image_slug
  ssh_keys  = [digitalocean_ssh_key.core.id]
  user_data = file("${path.module}/../../config/ignition/digitalocean.ign")

  tags = ["opencode-dev-server", "coreos"]
}

resource "digitalocean_volume_attachment" "state" {
  droplet_id = digitalocean_droplet.server.id
  volume_id  = digitalocean_volume.state.id
}

# ── Project (groups resources in the DO console) ─────────────────────────────

resource "digitalocean_project" "server" {
  name        = var.project_name
  description = "PocketBastion — remote, security-minded AI devbox"
  purpose     = "Web Application"
  environment = "Development"

  # Only droplets and volumes are project-assignable; firewalls have no URN.
  resources = [
    digitalocean_droplet.server.urn,
    digitalocean_volume.state.urn,
  ]
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "digitalocean_firewall" "server" {
  name = "${var.droplet_name}-firewall"

  droplet_ids = [digitalocean_droplet.server.id]

  inbound_rule {
    protocol         = "udp"
    port_range       = "51820"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

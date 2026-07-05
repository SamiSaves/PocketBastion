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

# ── Data sources ─────────────────────────────────────────────────────────────

data "digitalocean_ssh_key" "default" {
  name = var.ssh_key_name
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

# ── Droplet ───────────────────────────────────────────────────────────────────

resource "digitalocean_droplet" "server" {
  name      = var.droplet_name
  region    = var.region
  size      = var.droplet_size
  image     = var.coreos_image_slug
  ssh_keys  = [data.digitalocean_ssh_key.default.id]
  user_data = file("${path.module}/../../config/ignition/digitalocean.ign")

  tags = ["opencode-dev-server", "coreos"]
}

resource "digitalocean_volume_attachment" "state" {
  droplet_id = digitalocean_droplet.server.id
  volume_id  = digitalocean_volume.state.id
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "digitalocean_firewall" "server" {
  name = "${var.droplet_name}-firewall"

  droplet_ids = [digitalocean_droplet.server.id]

  # Allow WireGuard from anywhere
  inbound_rule {
    protocol         = "udp"
    port_range       = "51820"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Allow all outbound
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

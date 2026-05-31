output "droplet_id" {
  description = "ID of the created droplet."
  value       = digitalocean_droplet.server.id
}

output "droplet_ipv4" {
  description = "Public IPv4 address of the droplet."
  value       = digitalocean_droplet.server.ipv4_address
}

output "state_volume_id" {
  description = "ID of the persistent state volume."
  value       = digitalocean_volume.state.id
}

output "wireguard_endpoint" {
  description = "WireGuard endpoint to use in client configs."
  value       = "${digitalocean_droplet.server.ipv4_address}:51820"
}

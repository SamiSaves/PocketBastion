# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────┐
│  Laptop / CI runner                                      │
│                                                          │
│  Butane YAML ──butane──► Ignition JSON                   │
│                                  │                       │
│                         virt-install / cloud-init        │
│                                  │                       │
└──────────────────────────────────┼──────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │  Fedora CoreOS VM / Droplet  │
                    │                              │
                    │  firewalld (default: drop)   │
                    │  WireGuard  :51820/udp        │
                    │                              │
                    │  ┌─── VPN tunnel ───────┐    │
                    │  │                      │    │
                    │  │  opencode  :3000     │    │
                    │  │  game-dev  :5173     │    │
                    │  │                      │    │
                    │  └──────────────────────┘    │
                    │                              │
                    │  /mnt/state  (persistent)    │
                    └──────────────────────────────┘
```

## Components

### Fedora CoreOS

Immutable, auto-updating OS. Provisioned once via Ignition; never mutated by
configuration management tools. OS disk is disposable — all persistent data
lives on `/mnt/state`.

### Butane / Ignition

Butane (`.bu`) files are human-readable YAML configs that compile to Ignition
JSON. Ignition runs once at first boot to lay down users, files, and systemd
units.

### WireGuard

Point-to-point VPN. The server generates its key pair on first boot and stores
them under `/mnt/state/wireguard/`. Client peers are listed in
`/mnt/state/wireguard/peers.yaml`.

### Podman Quadlet

Systemd-native container management. Each service is a `.container` unit file
under `/etc/containers/systemd/`. Podman manages pull, start, stop, and restart
without a daemon.

### Persistent state volume

`/mnt/state` is a separate block device (or DigitalOcean Volume). It holds:

- `wireguard/` — key pairs and peer configs
- `repos/` — checked-out repositories
- `opencode/` — session data and model cache
- `cache/` — npm / pip / dnf caches

### Firewalld

Default zone: `drop`. Only two holes:

| Port | Protocol | Purpose |
|------|----------|---------|
| 51820 | UDP | WireGuard |
| 22 | TCP | SSH (local only, removed on DO) |

All application ports are reachable only through the WireGuard interface.

## Environments

| Environment | Provisioning | State disk | Public IP |
|-------------|-------------|------------|-----------|
| Local (KVM) | `virt-install` | virsh volume | No |
| DigitalOcean | Terraform + user-data | DO Volume | Yes (behind WG) |

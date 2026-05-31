# opencode-server

A reproducible, disposable Fedora CoreOS dev server that runs locally first
(KVM/libvirt), then later on DigitalOcean.

## Design principle

> The OS is cattle. `/mnt/state` is the only pet.

## What the server provides

- **WireGuard VPN** — all services are reachable only through the VPN tunnel.
- **OpenCode web UI** — AI coding assistant, VPN-only.
- **Vite + Phaser game dev server** — hot-reload dev server, VPN-only.
- **GitHub access** — pull/push with narrowly scoped deploy keys.
- **Persistent state** — repositories, OpenCode sessions, and package caches
  live on `/mnt/state` and survive OS rebuilds.

## Repository layout

```
config/
  butane/          Butane (YAML) source configs for Ignition
  ignition/        Rendered Ignition JSON (git-ignored, generated)
docs/
  architecture.md  System design and component overview
  operations.md    Day-to-day runbook
  security.md      Threat model and hardening decisions
  decisions.md     Architecture decision records (ADRs)
github-actions/    CI/CD workflows for start/destroy
quadlet/           Podman Quadlet unit files for containers
scripts/           Helper scripts (check, create, destroy, SSH…)
terraform/
  digitalocean/    Terraform for DigitalOcean droplet lifecycle
wireguard/
  templates/       wg0 and client config templates
  peers.example.yaml  Example peer list
Makefile           Developer shortcuts
```

## Quick start (local)

```bash
# 1. Check host prerequisites
./scripts/check-prereqs.sh

# 2. Render Ignition config
make ignition-local

# 3. Validate configs
make validate

# 4. Create local VM
make vm-create

# 5. SSH in
make ssh
```

## Phased rollout

| Phase | Goal |
|-------|------|
| 0 | Repository bootstrap (this phase) |
| 1 | Host prerequisites check |
| 2 | Minimal CoreOS local boot |
| 3 | WireGuard VPN |
| 4 | OpenCode container |
| 5 | Game dev server container |
| 6 | GitHub credentials |
| 7 | Persistent state volume |
| 8 | DigitalOcean Terraform |
| 9 | Scheduled teardown |

## Security notes

- No secrets are committed to this repository.
- WireGuard private keys are generated on first boot and stored in `/mnt/state`.
- GitHub credentials use narrowly scoped deploy keys, not personal access tokens.
- All inbound traffic except WireGuard UDP is blocked by firewalld.

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
    files/         Scripts + unit files inlined into Ignition at render time
  ignition/        Rendered Ignition JSON (git-ignored, generated)
docs/
  architecture.md  System design and component overview
  operations.md    Day-to-day runbook
  security.md      Threat model and hardening decisions
  decisions.md     Architecture decision records (ADRs)
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
make local-up

# 5. SSH in
make local-ssh
```

## Phased rollout

The full phased plan lives in [plan.md](plan.md).

## Security notes

- No secrets are committed to this repository.
- WireGuard private keys are generated on first boot and stored in `/mnt/state`.
- GitHub credentials use narrowly scoped deploy keys, not personal access tokens.
- All inbound traffic except WireGuard UDP is blocked by firewalld.

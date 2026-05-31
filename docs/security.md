# Security

## Threat model

| Threat | Mitigation |
|--------|------------|
| Unauthorized access to services | All ports except WireGuard UDP are blocked by firewalld |
| Secret leakage via git | `.gitignore` excludes keys, `.tfvars`, and `.env` files |
| Compromised GitHub token | Deploy keys scoped to a single repository, read-only where possible |
| Persistent OS vulnerability | CoreOS auto-updates; OS disk is disposable and re-provisioned frequently |
| Leaked WireGuard keys | Keys generated on first boot; stored only on `/mnt/state`, never in git |
| Container escape | Podman rootless where possible; SELinux enforcing on CoreOS |
| Midnight cost runaway | Scheduled GitHub Actions teardown; Terraform `terraform destroy` on cron |

## Firewall rules

Default zone is `drop`. Explicitly allowed:

```
51820/udp  — WireGuard
22/tcp     — SSH (local environment only)
```

SSH is removed from the DigitalOcean config; access is entirely via WireGuard.

## Secret inventory

No long-lived secrets live in this repository. The table below documents where
each secret lives at runtime:

| Secret | Location at runtime | Rotation |
|--------|---------------------|---------|
| WireGuard server private key | `/mnt/state/wireguard/server.key` | On VM rebuild |
| WireGuard client private key | Client device only | Manual |
| GitHub deploy key (private) | `/mnt/state/github/deploy.key` | Manual |
| GitHub deploy key (public) | Registered in GitHub repository settings | On key rotation |
| DigitalOcean API token | Terraform environment variable / GitHub Actions secret | Manual |

## CoreOS hardening (applied via Butane)

- SELinux: enforcing mode (CoreOS default).
- No password authentication for SSH; key-only.
- `core` user has a locked password.
- Auto-updates enabled via `zincati`.

## Dependency supply chain

- Container images are referenced by digest in Quadlet files to prevent tag
  hijacking.
- Butane image is pulled from the official `quay.io/coreos/butane` registry.
- Terraform provider versions are pinned in `versions.tf` (to be added in
  Phase 8).

# Operations runbook

## Local VM

### Create

```bash
make vm-create
```

### SSH

```bash
make ssh
# or directly:
./scripts/local/ssh.sh
```

### Get IP

```bash
make ip
```

### Serial console (if SSH is unavailable)

```bash
make console
# Exit with: Ctrl+]
```

### Destroy

```bash
make vm-destroy
```

## Regenerate Ignition config

After editing a Butane file:

```bash
make ignition-local   # for local
make ignition-do      # for DigitalOcean
make validate         # sanity check
```

## WireGuard peers

1. Generate a peer key pair on the client:
   ```bash
   wg genkey | tee peer.key | wg pubkey > peer.pub
   ```
2. Add the peer public key to `/mnt/state/wireguard/peers.yaml` on the server.
3. Reload WireGuard: `sudo systemctl restart wg-quick@wg0`.
4. Configure the client with the server's public key and endpoint.

## GitHub access

1. Generate the deploy key on the VM and print its public half:
   ```bash
   make github-install-deploy-key
   ```
2. Add the printed public key to the repo: GitHub → repo → Settings → Deploy
   keys → Add deploy key (tick "Allow write access").
3. Verify authentication:
   ```bash
   make github-test-access
   ```

The private key stays on the VM's state disk (`/mnt/state/secrets/github/`) and
survives rebuilds. Re-run `make github-install-deploy-key` after a rebuild to
restore `~/.ssh/config` (it reuses the persisted key — no GitHub re-registration).

## DigitalOcean

### Create droplet

```bash
cd terraform/digitalocean
terraform init
terraform apply
```

### Destroy droplet

```bash
cd terraform/digitalocean
terraform destroy
```

The GitHub Actions workflow `destroy-dev.yml` can also run this automatically
at midnight.

## Updating containers

Container images are pinned by digest in the Quadlet files. To update:

1. Pull the new image and record its digest.
2. Edit the relevant `.container` file in `quadlet/`.
3. Re-render Ignition (`make ignition-local` or `make ignition-do`).
4. Recreate the VM, or on a live machine:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart opencode.service
   ```

## Checking service status on the VM

```bash
systemctl status opencode.service
systemctl status game-dev.service
journalctl -u opencode.service -f
```

## Hardening check

After the VM is up and WireGuard is proven, verify the security model at
runtime:

```bash
make harden-check
```

It asserts: OpenCode/Vite are not on a public interface, SSH password + root
login are disabled, WireGuard is listening, `/mnt/state` is a separate
(persistent) mount, and no secrets are tracked by git. The "SSH over
WireGuard" check is skipped unless the tunnel is up on the machine running it.

## Emergency access

Normal access is SSH over WireGuard only. If the tunnel breaks (bad key, wg0
down, firewall lockout), recover **out-of-band** — do not open public SSH
permanently.

**1. Serial console (no network needed).**

- Local KVM: `make local-console` (exit with `Ctrl+]`).
- DigitalOcean: droplet → **Access** → **Launch Droplet Console**.

Log in as `core` with your SSH key via the console, then inspect:

```bash
sudo systemctl status wg-quick@wg0 firewall.service
sudo wg show
sudo journalctl -u wg-setup.service -u firewall.service
```

**2. Temporarily re-open public SSH (local debug).** The firewall reads a
persistent toggle from the state disk. From the console:

```bash
echo 'ALLOW_PUBLIC_SSH_FOR_LOCAL_DEBUG=true' \
  | sudo tee /mnt/state/firewall/firewall.env
sudo systemctl restart firewall.service
```

Flip it back to `false` (and restart `firewall.service`) the moment WireGuard
works again. Because the file lives on `/mnt/state`, the setting survives VM
recreation — so do not leave it on.

**3. Last resort — rebuild.** The OS disk is disposable. Destroy and recreate
the VM; `/mnt/state` (keys, repos, sessions) is reattached untouched:

```bash
make local-down && make local-up   # local
# DigitalOcean: re-run the start workflow / terraform apply (volume persists)
```

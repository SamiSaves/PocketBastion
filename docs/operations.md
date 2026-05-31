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
./scripts/local-ssh.sh
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

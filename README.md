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
  templates/       wg0 config reference (server-side)
  peers.example.yaml  Example peer address plan
Makefile           Developer shortcuts
```

## Quick start (local)

```bash
# 1. Check host prerequisites
./scripts/local/prereqs.sh

# 2. Render Ignition config
make ignition-local

# 3. Validate configs
make validate

# 4. Create local VM
make local-up

# 5. SSH in
make local-ssh
```

## Connecting over WireGuard

This repo never generates, stores, or transports a client private key. Each device makes its own keypair; only **public** keys are ever shared. Follow the steps in order — there is no step that puts a private key on your disk or in a QR code.

1. **Get the server's public key** (once the VM is up):
   ```bash
   make wg-server-pubkey # saves secrets/wireguard/server.public and prints it
   ```

2. **Generate the keypair on the device that will connect:**
   - **Phone:** open the WireGuard app → *Add tunnel* → *Create from scratch*. The
     app generates the keypair for you. Copy the **Public key** it shows.
   - **Laptop/desktop (Linux):** generate a keypair; the private key goes into
     the config file in step 4, and you share only the public key:
     ```bash
     umask 077; wg genkey | tee privatekey | wg pubkey
     ```
     This prints the **public** key (for step 3) and writes the **private** key
     to `privatekey`. It stays on this machine and goes into step 4's config.

3. **Register the device's PUBLIC key** on the server:
   ```bash
   make wg-add-peer PEER=phone IP=10.44.0.4 PUBKEY=<paste the public key>
   ```

4. **Create the device tunnel config.** This is the file WireGuard itself uses;
   it lives on the device, never in this repo. All fields are non-secret except
   `PrivateKey`, which the device already holds from step 2:
   ```ini
   [Interface]
   Address    = 10.44.0.4/24          # the IP you registered in step 3
   PrivateKey = <stays on the device, from step 2>

   [Peer]
   PublicKey           = <server public key from step 1>
   Endpoint            = <server-ip>:51820
   AllowedIPs          = 10.44.0.0/24
   PersistentKeepalive = 25
   ```
   - **Phone:** enter these fields into the tunnel you started in step 2; the
     app stores it in its own secure storage.
   - **Laptop/desktop (Linux):** save it as `/etc/wireguard/<name>.conf`
     (root, `chmod 600`), pasting the contents of `privatekey` into the
     `PrivateKey` line, then delete the `privatekey` file.

5. **Bring the tunnel up** — toggle it on in the phone app, or run
   `sudo wg-quick up <name>` on Linux. Only now are SSH, OpenCode, and the
   other services reachable — everything is VPN-only.

Address plan: server `10.44.0.1`, laptop `.2`, desktop `.3`, phone `.4`.

## OpenCode setup

OpenCode is configured **once, after the server is up and reachable over
WireGuard**. Everything here lives on `/mnt/state`, so it survives droplet
teardown — you only redo it if the persistent disk is destroyed.

1. **Connect over WireGuard** (above), then SSH in over the tunnel:
   ```bash
   ssh core@10.44.0.1        # or: make local-ssh
   ```

2. **Set the server password** (protects the UI even inside the VPN). It is read
   from `/mnt/state/secrets/opencode.env` by the container:
   ```bash
   printf 'OPENCODE_SERVER_PASSWORD=%s\n' 'your-strong-password' \
     > /mnt/state/secrets/opencode.env
   chmod 600 /mnt/state/secrets/opencode.env
   ```
   Optional: add raw provider keys here instead of step 3, one per line
   (`ANTHROPIC_API_KEY=…`, `OPENAI_API_KEY=…`).

3. **Authenticate a provider** — an interactive login (e.g. GitHub Copilot's
   device flow) that can't be pre-baked. Run it inside the container; it
   persists to `/mnt/state/opencode`:
   ```bash
   podman exec -it opencode opencode auth login
   ```

4. **Restart the service** to pick up the env file:
   ```bash
   systemctl --user restart opencode.service
   ```

The UI is then reachable at `http://10.44.0.1:4096` over the VPN.

## Security notes

- No secrets are committed to this repository.
- The WireGuard **server** key is generated on first boot and stored in `/mnt/state`.
- WireGuard **client** keys are generated on each device; only public keys are
  ever shared. This repo never generates, stores, or transports a client private key.
- GitHub credentials use narrowly scoped deploy keys, not personal access tokens.
- All inbound traffic except WireGuard UDP is blocked by firewalld.

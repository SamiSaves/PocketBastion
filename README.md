# opencode-server

A reproducible, disposable Fedora CoreOS dev server that runs the OpenCode web
UI behind a WireGuard VPN. It runs locally first (KVM/libvirt) and on
DigitalOcean from the same config. The OS is disposable; only `/mnt/state`
(repos, OpenCode sessions, caches) survives a rebuild.

All services — SSH, the OpenCode UI, the dev server — are reachable **only**
through the WireGuard tunnel. The one break-glass path is the serial console.

## Getting started (local)

The local VM is WireGuard-only, exactly like the cloud one. That means your
device's VPN public key has to be baked into the image **before** the VM is
created, so the tunnel is up the moment it boots. The order below reflects that.

### 1. Host prerequisites

Check for the required tools and libvirt/kvm group membership:

```bash
./scripts/local/prereqs.sh
```

The script prints the exact install command if anything is missing. Then do the
one-time libvirt setup (creates the storage pool):

```bash
./scripts/local/setup.sh
```

Download the Fedora CoreOS QEMU image and place it where the VM expects it:

```bash
# https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
# Bare Metal & Virtualized → QEMU (qcow2.xz)
xz -d fedora-coreos-*.qcow2.xz
sudo mv fedora-coreos-*.qcow2 /var/lib/libvirt/images/fedora-coreos-44.qcow2
```

### 2. Configure `deploy.env`

Everything the build needs — your SSH public key and your WireGuard public key —
goes into a single `deploy.env` file. There's no `secrets/` folder and no magic
defaults: whatever you put here is exactly what gets baked in. Both values are
**public** keys; private keys never enter this repo.

```bash
cp deploy.env.example deploy.env
```

Now open `deploy.env` and fill in the two values below.

#### SSH public key

Paste your SSH **public** key into `SSH_AUTHORIZED_KEY` — this is what lets you
log in over the tunnel:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"
```

<details>
<summary>Don't have a key? How to create one</summary>

Create a dedicated key so it's easy to identify and revoke later:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/opencode -C opencode
```

This writes the private key to `~/.ssh/opencode` (keep it) and the public key to
`~/.ssh/opencode.pub`. Print the public half to paste into `deploy.env`:

```bash
cat ~/.ssh/opencode.pub
```

To have SSH use this key automatically, add to `~/.ssh/config`:

```
Host opencode
    HostName     10.44.0.1
    User         core
    IdentityFile ~/.ssh/opencode
```

</details>

#### WireGuard public key

Paste your device's WireGuard **public** key into `WG_BOOTSTRAP_PUBKEY`. This
seeds peer #0 so the VPN tunnel is up the moment the VM boots — before SSH even
exists. Leave `WG_BOOTSTRAP_IP` at `.2` unless you're changing the address plan:

```bash
WG_BOOTSTRAP_PUBKEY=<your device's WireGuard public key>
WG_BOOTSTRAP_IP=10.44.0.2
```

<details>
<summary>Don't have a WireGuard keypair? How to create one</summary>

There's no standard per-user WireGuard directory like `~/.ssh`, and
`/etc/wireguard` is root-owned — so keep your keys in your own config dir:

```bash
mkdir -p ~/.config/wireguard && chmod 700 ~/.config/wireguard
umask 077
wg genkey | tee ~/.config/wireguard/opencode.key | wg pubkey \
  > ~/.config/wireguard/opencode.pub
cat ~/.config/wireguard/opencode.pub   # the PUBLIC key to paste above
```

`opencode.key` is your private key — it stays on this machine and you'll use it
in step 4. `opencode.pub` is the public key you paste into `deploy.env`.

</details>

### 3. Create the VM

Renders the Ignition config and boots the VM:

```bash
make local-up
```

### 4. Bring up your tunnel

SSH is tunnel-only, so you need the server's public key first — and the tunnel
isn't up yet on first boot. Get it from the console, which is the only pre-tunnel
way in (this is also your break-glass path if WireGuard ever fails):

```bash
make local-console
```

Log in as `core` with the public default password **`space-depend-south`**, then
**change it right away** with `passwd` — it's a known default committed in the
repo, so treat your first login as the moment to replace it. Then read the
server's public key:

```bash
passwd                                          # set your own password
sudo cat /mnt/state/wireguard/server_public.key
# Ctrl-] to exit the console
```

> The default password is only ever usable on the console (local serial or, on
> DigitalOcean, the web console behind your DO account). SSH stays key-only and
> WireGuard-only, so this password is never reachable from the internet.

Create the tunnel config next to your keys as
`~/.config/wireguard/opencode.conf`, pasting your private key
(`cat ~/.config/wireguard/opencode.key`) and the server public key:

```ini
[Interface]
Address    = 10.44.0.2/24
PrivateKey = <contents of ~/.config/wireguard/opencode.key>

[Peer]
PublicKey           = <server public key from the console>
Endpoint            = <vm-ip>:51820
AllowedIPs          = 10.44.0.0/24
PersistentKeepalive = 25
```

Use `make local-ip` for the VM's LAN IP (the `Endpoint`). Then bring the tunnel
up by pointing `wg-quick` at that file — the interface name comes from the
filename (`opencode`). Only this step needs root; the config stays in your home:

```bash
sudo wg-quick up ~/.config/wireguard/opencode.conf
# down again with: sudo wg-quick down ~/.config/wireguard/opencode.conf
```

Once the tunnel is up you can fetch the server key over SSH next time instead of
the console:

```bash
make wg-server-pubkey
```

### 5. Post-install setup

SSH in over the tunnel:

```bash
make local-ssh          # ssh core@10.44.0.1
```

Everything below lives on `/mnt/state`, so you only do it once — it survives VM
teardown.

**Set the OpenCode server password** (read by the container from
`/mnt/state/secrets/opencode.env`):

```bash
printf 'OPENCODE_SERVER_PASSWORD=%s\n' 'your-strong-password' \
  > /mnt/state/secrets/opencode.env
chmod 600 /mnt/state/secrets/opencode.env
```

Optionally add provider keys to the same file, one per line
(`ANTHROPIC_API_KEY=…`, `OPENAI_API_KEY=…`).

**Authenticate a provider** with an interactive login that can't be pre-baked
(e.g. GitHub Copilot's device flow):

```bash
podman exec -it opencode opencode auth login
```

**Restart the service** to pick up the env file:

```bash
systemctl --user restart opencode.service
```

The UI is then reachable at `http://10.44.0.1:4096` over the VPN.

### Adding more devices

Address plan: server `10.44.0.1`, laptop `.2`, desktop `.3`, phone `.4`.

For each new device, generate its keypair on the device (WireGuard app, or
`wg genkey`), then register only its **public** key on the server:

```bash
make wg-add-peer PEER=phone IP=10.44.0.4 PUBKEY=<device public key>
```

This appends to `/mnt/state/wireguard/peers.conf` (survives VM recreation) and
restarts WireGuard.

### Git access

Each repo gets its own deploy key, generated on the VM and never leaving the
state disk. Works with any SSH git host (github.com, gitlab.com, self-hosted).
Access is per-repo and explicit — adding a repo is a deliberate step:

```bash
make repo-add REPO=git@github.com:owner/name.git
make repo-list
make repo-remove NAME=github-com-owner-name              # keeps the checkout
make repo-remove NAME=github-com-owner-name PURGE=1      # also deletes it
```

`repo-add` pauses while you register the printed public key on the repo (as a
deploy key), then verifies by cloning. For hosts other than github.com it shows
the server's SSH fingerprint for a one-time confirmation. The container gets the
per-repo deploy key directly — a leaked key grants write to only that one repo,
a smaller blast radius than the API keys already in the container.

## Managing the VM

```bash
make local-ssh          # SSH in over the tunnel
make local-console      # serial console (break-glass, no tunnel needed)
make local-ip           # print the VM's LAN IP
make local-down         # destroy the VM, keep the state disk
make local-wipe-state   # permanently delete the state disk (DATA LOSS)
make validate           # validate scripts and configs
```

Run `make help` for the full list of targets.

## DigitalOcean

The same config deploys to a droplet via Terraform. Set the bootstrap peer in
`deploy.env` as above, export `TF_VAR_do_token`, then:

```bash
make ignition-do
make tf-apply           # uses ./deploy.tfvars
```

Getting the server key and breaking glass work the same as local, via DO's web
**Droplet Console**: log in as `core` with the default password
`space-depend-south`, change it with `passwd`, then
`sudo cat /mnt/state/wireguard/server_public.key`. That console sits behind your
DigitalOcean account login, so the default password is never internet-reachable.

Because SSH is WireGuard-only, the console is your only recovery path if the
tunnel breaks. If that's not enough, the OS is disposable: destroy and recreate
the droplet — the state Volume (keys, peers, repos) is preserved
(`prevent_destroy`), so a rebuild reuses the same WireGuard identity. Note a
rebuilt droplet gets a new public IP, so clients update their `Endpoint` (not
their keys); a DO Reserved IP avoids even that.

## Security notes

- No secrets are committed to this repository.
- The `core` user has a **public, default console password** (`space-depend-south`)
  for break-glass only. Change it on your first console login; sshd is key-only
  and WireGuard-only, so it is never usable over the network.
- The WireGuard **server** key is generated on first boot, stored on `/mnt/state`,
  and reused across VM/droplet rebuilds — teardown does not force clients to
  reconfigure. Only wiping the state disk/volume regenerates it.
- WireGuard **client** keys are generated on each device; only public keys are
  ever shared. This repo never generates, stores, or transports a client private key.
- GitHub credentials use narrowly scoped deploy keys, not personal access tokens.
- All inbound traffic except WireGuard UDP is blocked by the firewall.

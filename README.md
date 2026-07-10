# PocketBastion

> A remote, security-minded AI devbox.

PocketBastion is a disposable, reproducible AI dev server. It runs the OpenCode
web UI on Fedora CoreOS, locked entirely behind a WireGuard VPN so you can code
from anywhere, including your phone, without exposing anything to the public
internet. It runs on any platform, but this has been setup for DigitalOcean,
it also runs locally wiht (KVM/libvirt). The OS is disposable, but `/mnt/state`
repos, OpenCode sessions, caches and configs survive a rebuild.

All services (SSH, the OpenCode UI, the dev server) are reachable **only**
through the WireGuard tunnel. The one break-glass path is the serial console.

## Getting started

The server is WireGuard-only from first boot, so your device's WireGuard public
key is baked into the image **before** the VM exists. The steps follow that order.

### 1. Prerequisites

Install [Terraform](https://developer.hashicorp.com/terraform/install) and export
your DigitalOcean API token:

```bash
export TF_VAR_do_token=<your DigitalOcean API token>
```

<details>
<summary>Local (KVM/libvirt) instead?</summary>

Check tools and libvirt/kvm group membership, then do the one-time setup:

```bash
./scripts/local/prereqs.sh   # prints the install command if anything is missing
./scripts/local/setup.sh     # creates the libvirt storage pool
```

Download the Fedora CoreOS QEMU image where the VM expects it:

```bash
# https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
# Bare Metal & Virtualized → QEMU (qcow2.xz)
xz -d fedora-coreos-*.qcow2.xz
sudo mv fedora-coreos-*.qcow2 /var/lib/libvirt/images/fedora-coreos-44.qcow2
```
</details>

### 2. Configure `deploy.env`

```bash
cp deploy.env.example deploy.env
```

Fill in two **public** keys (private keys never enter this repo):

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"         # log in over the tunnel
WG_BOOTSTRAP_PUBKEY=<your device's WireGuard public key>   # seeds VPN peer #0, up before SSH
WG_BOOTSTRAP_IP=10.44.0.2                                  # this device's VPN address (unique in 10.44.0.0/24)
```

<details>
<summary>Don't have a key? How to create one</summary>

Create a dedicated key so it's easy to identify and revoke later:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pocketbastion -C pocketbastion
```

This writes the private key to `~/.ssh/pocketbastion` (keep it) and the public key to
`~/.ssh/pocketbastion.pub`. Print the public half to paste into `deploy.env`:

```bash
cat ~/.ssh/pocketbastion.pub
```

To have SSH use this key automatically, add to `~/.ssh/config`:

```
Host pocketbastion
    HostName     10.44.0.1
    User         core
    IdentityFile ~/.ssh/pocketbastion
```

</details>

<details>
<summary>Don't have a WireGuard keypair? How to create one</summary>

There's no standard per-user WireGuard directory like `~/.ssh`, and
`/etc/wireguard` is root-owned — so keep your keys in your own config dir:

```bash
mkdir -p ~/.config/wireguard && chmod 700 ~/.config/wireguard
umask 077
wg genkey | tee ~/.config/wireguard/pocketbastion.key | wg pubkey \
  > ~/.config/wireguard/pocketbastion.pub
cat ~/.config/wireguard/pocketbastion.pub   # the PUBLIC key to paste above
```

`pocketbastion.key` is your private key — it stays on this machine and you'll use it
in step 4. `pocketbastion.pub` is the public key you paste into `deploy.env`.

</details>

### 3. Create the server

```bash
make ignition-do
make tf-apply          # uses ./deploy.tfvars
```

<details>
<summary>Local instead?</summary>

```bash
make local-up          # renders Ignition and boots the KVM VM
```
</details>

### 4. Bring up your tunnel

The tunnel isn't up yet, so get the server's public key from DO's web **Droplet
Console** (also your break-glass path if WireGuard ever fails). Log in as `core`
with the default password **`space-depend-south`**, change it, then read the key:

```bash
passwd                                          # set your own password
sudo cat /mnt/state/wireguard/server_public.key
```

> The default password only works on the console (behind your DO account login).
> SSH stays key-only and WireGuard-only, so it's never reachable from the internet.

<details>
<summary>Local instead?</summary>

Use the serial console:

```bash
make local-console
# then: passwd; sudo cat /mnt/state/wireguard/server_public.key; Ctrl-] to exit
```
</details>

Create the tunnel config next to your keys as
`~/.config/wireguard/pocketbastion.conf`, pasting your private key
(`cat ~/.config/wireguard/pocketbastion.key`) and the server public key:

```ini
[Interface]
Address    = 10.44.0.2/24
PrivateKey = <contents of ~/.config/wireguard/pocketbastion.key>

[Peer]
PublicKey           = <server public key from the console>
Endpoint            = <vm-ip>:51820
AllowedIPs          = 10.44.0.0/24
PersistentKeepalive = 25
```

The `Endpoint` is the droplet's public IP: `cd terraform/digitalocean && terraform
output wireguard_endpoint` (for local, `make local-ip`). Then bring the tunnel up
by pointing `wg-quick` at the file — the interface name comes from the filename
(`pocketbastion`). Only this step needs root; the config stays in your home:

```bash
sudo wg-quick up ~/.config/wireguard/pocketbastion.conf
# down again with: sudo wg-quick down ~/.config/wireguard/pocketbastion.conf
```

Once the tunnel is up you can fetch the server key over SSH next time instead of
the console:

```bash
make wg-server-pubkey
```

### 5. Post-install setup

SSH in over the tunnel:

```bash
ssh core@10.44.0.1      # same address on both envs; `make local-ssh` wraps this for local
```

Everything below lives on `/mnt/state`, so you only do it once — it survives
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

Give each device a unique address in `10.44.0.0/24` (the server is `.1`) and a
name to identify it. Generate its keypair on the device (WireGuard app, or
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
per-repo deploy key directly — a leaked key grants write to only that one repo.

## Managing the server

```bash
make tf-plan            # preview droplet changes
make tf-apply           # apply droplet changes (rebuilds reuse the state Volume)
make wg-server-pubkey   # fetch the server WireGuard key over the tunnel
make validate           # validate scripts and configs
make help               # full list of targets
```

The OS is disposable: destroy and recreate the droplet and the state Volume
(keys, peers, repos) is preserved (`prevent_destroy`), so a rebuild reuses the
same WireGuard identity. A rebuilt droplet gets a new public IP, so clients
update their `Endpoint` (not their keys); a DO Reserved IP avoids even that. 
As of now the core os password needs to be reset after each recreate.

<details>
<summary>Local VM management</summary>

```bash
make local-up           # create the VM
make local-console      # serial console (break-glass, no tunnel needed)
make local-ip           # print the VM's LAN IP
make local-ssh          # SSH in over the tunnel
make local-down         # destroy the VM, keep the state disk
make local-wipe-state   # permanently delete the state disk (DATA LOSS)
```
</details>

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

## TODO

- Run repository applicaitons in dev mode and make them accessible via browser through WireGuard
- Improve security stance on opencode container, see if we can avoid it having so many secrets, such as git ssh keys
- See if we could host vscode server for better development experience
- Tests (and validation)
- Small security audit
- Make core os password configurable

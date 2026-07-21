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

### 1. Set up WireGuard

WireGuard is the prerequisite for everything else — your public key is baked into
the image before the VM exists. Follow [docs/wireguard.md](docs/wireguard.md) to
create your keypair and tunnel config.

### 2. Configure `deploy.env`

```bash
cp deploy.env.example deploy.env
```

Fill in two **public** keys (private keys never enter this repo):

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"         # log in over the tunnel
WG_BOOTSTRAP_PUBKEY=<your device's WireGuard public key>   # from docs/wireguard.md; seeds VPN peer #0
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

### 3. Create your server & connect

Follow the guide for your platform — each covers its prerequisites, creating the
server, and connecting your tunnel:

- [DigitalOcean](docs/digitalocean.md)
- [Local (KVM/libvirt)](docs/local.md)

### 4. Post-install setup

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

### Running a dev server

Only ports you list are forwarded from the tunnel into OpenCode's (untrusted,
network-isolated) container. Add them to `OPENCODE_EXTRA_PORTS` in `deploy.env`
(space-separated ports/ranges), then re-render and redeploy:

```bash
OPENCODE_EXTRA_PORTS="3000 5173 8000-8010"
```

Start the server bound to `0.0.0.0` (not `10.44.0.1`, which the container can't
see); it's then reachable at `http://10.44.0.1:<port>` over the VPN:

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

### Adding more devices

Generate each device's keypair on the device, then register only its **public**
key on the server:

```bash
make wg-add-peer PEER=phone IP=10.44.0.4 PUBKEY=<device public key>
```

See [docs/wireguard.md](docs/wireguard.md#adding-more-devices) for details.

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

Platform lifecycle commands live in the platform guides
([DigitalOcean](docs/digitalocean.md#managing-the-droplet),
[Local](docs/local.md#managing-the-vm)). Common targets:

```bash
make wg-server-pubkey   # fetch the server WireGuard key over the tunnel
make validate           # validate scripts and configs
make help               # full list of targets
```

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
- Consider DNS for VM
- Conisder DNS to recover wireguard automatically from a droplet ip change
- Consider custom web UI for managing the server

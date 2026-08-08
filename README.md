# PocketBastion

> A remote, security-minded AI devbox.

PocketBastion is a disposable, reproducible AI dev server. It runs the OpenCode
web UI on Fedora CoreOS so you can code from anywhere, including your phone,
without exposing anything to the public internet. The OS is disposable; the
repos, OpenCode sessions, caches and configs on `/mnt/state` survive a rebuild.

Supported platforms: **Raspberry Pi 4** and **local KVM/libvirt**.

## Network modes

How the box is reached — and therefore what the firewall allows — is a single
setting, `NETWORK_MODE`:

| | `wireguard` (default) | `lan` |
|---|---|---|
| VPN | The box runs its own WireGuard | None; your network already has one |
| Exposed | UDP 51820 only | SSH + published ports, from `TRUSTED_CIDRS` only |
| Services bind to | `10.44.0.1` (the tunnel) | `0.0.0.0`, filtered by nftables |
| Break-glass | Serial console | Serial console |
| Use for | Anything on the public internet | A Pi on your own LAN |

`wireguard` is the default and the safe answer. In `lan` mode the render
**refuses** to produce a config without `TRUSTED_CIDRS` and rejects `0.0.0.0/0`.
The UI is plaintext HTTP in that mode, so set a server password on the box.

Each `deploy.env` picks one mode. For a second box in a different mode, copy it
and point the render at the copy:

```bash
cp deploy.env deploy.rpi.env       # NETWORK_MODE=lan in this one
DEPLOY_ENV=deploy.rpi.env make ignition-rpi
```

## Getting started

### 1. Set up WireGuard

Skip this if you are using `lan` mode; go to step 2.

In `wireguard` mode the server is WireGuard-only from first boot, so your
device's public key is baked into the image **before** the VM exists. Follow
[docs/wireguard.md](docs/wireguard.md) to create your keypair and tunnel config.

### 2. Configure `deploy.env`

```bash
cp deploy.env.example deploy.env
```

Fill in your SSH **public** key (private keys never enter this repo), then the
settings for your chosen network mode:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"          # log in to the server

# wireguard mode (default) — from docs/wireguard.md
WG_BOOTSTRAP_PUBKEY=<your device's WireGuard public key>   # seeds VPN peer #0
WG_BOOTSTRAP_IP=10.44.0.2                                  # unique in 10.44.0.0/24

# lan mode — instead of the two above
TRUSTED_CIDRS="192.168.1.0/24"                             # who may reach it
SERVER_HOST=pocketbastion-rpi.lan                          # where `make` targets connect
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
server, and connecting to it:

- [Raspberry Pi 4](docs/raspberry-pi.md)
- [Local (KVM/libvirt)](docs/local.md)

### 4. Post-install setup

SSH in:

```bash
ssh core@10.44.0.1        # wireguard mode; `make local-ssh` wraps this for local
ssh core@$SERVER_HOST     # lan mode
```

Everything below lives on `/mnt/state`, so you only do it once — it survives
teardown.

**Set the OpenCode server password** (read by the container from
`/mnt/state/secrets/opencode.env`):

```bash
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$(openssl rand -base64 24)" \
  > /mnt/state/secrets/opencode.env
chmod 600 /mnt/state/secrets/opencode.env
```

In `lan` mode this is the only credential in front of the UI, which is plaintext
HTTP there. In `wireguard` mode the tunnel is the credential, but set one anyway.

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

The UI is then reachable at `http://10.44.0.1:4096` (wireguard) or
`http://<server>:4096` from a trusted network (lan).

### Running a dev server

Only ports you list are published from OpenCode's (untrusted,
network-isolated) container. Add them to `OPENCODE_EXTRA_PORTS` in `deploy.env`
(space-separated ports/ranges), then re-render and redeploy:

```bash
OPENCODE_EXTRA_PORTS="3000 5173 8000-8010"
```

In `lan` mode these are also exactly the ports the firewall opens to
`TRUSTED_CIDRS` — nothing else is reachable.

Start the server bound to `0.0.0.0` (not the host's address, which the container
can't see):

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

### Adding more devices

`wireguard` mode only. Generate each device's keypair on the device, then
register only its **public** key on the server:

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
([Raspberry Pi](docs/raspberry-pi.md#5-day-to-day),
[Local](docs/local.md#managing-the-vm)). Common targets:

```bash
make wg-server-pubkey   # fetch the server WireGuard key (wireguard mode)
make validate           # static checks: shellcheck, systemd, render
make help               # full list of targets
```

`SERVER_HOST` in `deploy.env` decides where these connect; override it for a
single command with `SERVER_HOST=192.168.1.42 make repo-list`.

## How the config is built

Every platform is a deep merge of three layers, compiled by Butane `--strict`:

```
base.bu  *+  <platform>.bu  *+  [features/<feature>.bu ...]
```

- **`base.bu`** — everything shared: the `core` user, sshd hardening, the
  OpenCode container and its build, git setup, the firewall script, swap.
- **`<platform>.bu`** — only what differs: `local.bu` and `rpi.bu` (hostname,
  how `/mnt/state` is provided).
- **`features/`** — optional layers. `wireguard.bu` is merged in only when
  `NETWORK_MODE=wireguard`; in `lan` mode not a single WireGuard file, unit or
  address is present in the output.

Invariant: every file path and unit name lives in **exactly one** layer. `*+`
appends arrays, so a duplicate would survive the merge and Butane `--strict`
rejects it.

## Testing

```bash
make validate       # shellcheck, systemd-analyze, render every platform/mode
```

`make validate` renders both platforms and asserts the layering: that every
shared block reaches every platform, that each platform gets only its own disk
layout, and that `lan` mode emits no WireGuard file, unit or address at all.

There is no runtime hardening check yet — the box's security properties are
asserted at render time only.

## Security notes

- No secrets are committed to this repository.
- The `core` user has a **public, default console password** (`space-depend-south`)
  for break-glass only. Change it on your first console login; sshd is key-only,
  so it is never usable over the network.
- **`wireguard` mode:** all inbound traffic except WireGuard UDP is dropped. SSH
  is not exposed publicly at all — break-glass is the serial console.
- **`lan` mode:** SSH and the published ports are opened to `TRUSTED_CIDRS`
  only; everything else is dropped. The render refuses an empty `TRUSTED_CIDRS`
  or `0.0.0.0/0`, and if `firewall.env` is ever hand-edited into that state the
  firewall applies a full lockdown rather than opening up. The OpenCode UI is
  plaintext HTTP in this mode, so its server password is the only credential in
  front of it — nothing enforces that you set one.
- The WireGuard **server** key is generated on first boot, stored on `/mnt/state`,
  and reused across rebuilds — teardown does not force clients to reconfigure.
  Only wiping the state disk/volume regenerates it.
- WireGuard **client** keys are generated on each device; only public keys are
  ever shared. This repo never generates, stores, or transports a client private key.
- Git credentials use narrowly scoped per-repo deploy keys, not personal access
  tokens.

## TODO

- Improve security stance on opencode container, see if we can avoid it having so many secrets, such as git ssh keys
- See if we could host vscode server for better development experience
- Small security audit
- Make core os password configurable
- Consider DNS for VM
- Consider custom web UI for managing the server

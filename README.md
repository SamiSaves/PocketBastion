# PocketBastion

> A remote, security-minded AI devbox.

PocketBastion is a disposable, reproducible AI dev server. It runs the OpenCode
web UI on Fedora CoreOS so you can code from any device on your own network,
including your phone, without exposing anything to the public internet. The OS is
disposable; the repos, OpenCode sessions, caches and configs on `/mnt/state`
survive a rebuild.

It runs on a **Raspberry Pi 4**. A local KVM VM mocks that Pi — same config,
same flasher, on a disk image — so changes can be tried before a card is
written.

## How it is reached

The box runs no VPN of its own, so the network it sits on has to be the gate:
put it on a LAN you reach over your own VPN, and never port-forward to it.
`TRUSTED_CIDRS` is then the whole access-control boundary in front of it:

| | |
|---|---|
| Services bind to | `0.0.0.0`, filtered by nftables |
| Exposed | SSH + the published ports, to `TRUSTED_CIDRS` only |
| Everything else | Dropped |
| Break-glass | Serial console |

The render **refuses** to produce a config without `TRUSTED_CIDRS` and rejects
`0.0.0.0/0`. The UI is plaintext HTTP, so set a server password on the box.

Each `deploy.env` describes one box. For a second one — the mock VM is on
libvirt's network, not your LAN — copy it and point the render at the copy:

```bash
cp deploy.env deploy.vm.env        # TRUSTED_CIDRS="192.168.122.0/24"
DEPLOY_ENV=deploy.vm.env make ignition
```

## Getting started

### 1. Configure `deploy.env`

```bash
cp deploy.env.example deploy.env
```

Fill in your SSH **public** key (private keys never enter this repo), who may
reach the box, and where `make` should connect:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"          # log in to the server
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
    HostName     pocketbastion-rpi.lan
    User         core
    IdentityFile ~/.ssh/pocketbastion
```

</details>

### 2. Create your server & connect

Each guide covers its prerequisites, creating the server, and connecting to it:

- [Raspberry Pi 4](docs/raspberry-pi.md) — the real thing
- [Local mock VM](docs/local.md) — the same image on KVM, for trying changes first

### 3. Post-install setup

SSH in (`make local-ssh` does this for the mock VM):

```bash
ssh core@$SERVER_HOST
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

Log in as `opencode` with that password. It is the only credential in front of
the UI, which is plaintext HTTP.

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

The UI is then reachable at `http://<server>:4096` from a trusted network.

### Running a dev server

Only ports you list are published from OpenCode's container. Add them to
`OPENCODE_EXTRA_PORTS` in `deploy.env` (space-separated ports/ranges), then
re-render and redeploy:

```bash
OPENCODE_EXTRA_PORTS="3000 5173 8000-8010"
```

These are also exactly the ports the firewall opens to `TRUSTED_CIDRS` —
nothing else is reachable.

Start the server bound to `0.0.0.0` (not the host's address, which the container
can't see):

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

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

Lifecycle commands live in the platform guides
([Raspberry Pi](docs/raspberry-pi.md#5-day-to-day),
[mock VM](docs/local.md#managing-the-vm)). Common targets:

```bash
make validate           # static checks: shellcheck, systemd, render
make help               # full list of targets
```

`SERVER_HOST` in `deploy.env` decides where these connect; override it for a
single command with `SERVER_HOST=192.168.1.42 make repo-list`.

## How the config is built

One file, `config/butane/pocketbastion.bu`: the whole box — the `core` user,
sshd hardening, the OpenCode container and its build, git setup, the firewall
script, zram, and the microSD partition layout. `make ignition` substitutes
`${VARS}` from `deploy.env` into it and compiles it with Butane `--strict`.

The mock VM boots this same output, unmodified. Nothing branches on "am I a
VM" — that is what makes it worth testing on.

## Testing

```bash
make validate       # shellcheck, systemd-analyze, render
make local-up       # boot the mock and try it for real
```

`make validate` is static: it renders the config and asserts that every expected
file and unit is present, that a missing or `0.0.0.0/0` `TRUSTED_CIDRS` is
refused rather than rendered, and that the two disk-layout numbers a reflash
depends on are unchanged.

Runtime behaviour is checked by running the mock. `make local-up` reflashes it
through the real `scripts/rpi/flash.sh`, so every rebuild also exercises
`--save-partlabel` and verifies the state partition did not move — the failure
that would otherwise cost you the data on a real card.

There is still no automated runtime hardening check; the mock is where you look
at the firewall by hand.

## Security notes

- No secrets are committed to this repository.
- The `core` user has a **public, default console password** (`space-depend-south`)
  for break-glass only. Change it on your first console login; sshd is key-only,
  so it is never usable over the network.
- SSH and the published ports are opened to `TRUSTED_CIDRS` only; everything
  else is dropped. The render refuses an empty `TRUSTED_CIDRS` or `0.0.0.0/0`,
  and if `firewall.env` is ever hand-edited into that state the firewall applies
  a full lockdown rather than opening up.
- The box runs no VPN of its own, so it is only as isolated as the network you
  put it on. The OpenCode UI is plaintext HTTP, so its server password is the
  only credential in front of it — nothing enforces that you set one.
- The firewall filters inbound only. The container's outbound access is
  unrestricted: an agent inside it can reach your LAN and the internet.
- Git credentials use narrowly scoped per-repo deploy keys, not personal access
  tokens.

## TODO

- Improve security stance on opencode container, see if we can avoid it having so many secrets, such as git ssh keys
- See if we could host vscode server for better development experience
- Make core os password configurable
- Consider DNS for the Pi
- Consider custom web UI for managing the server

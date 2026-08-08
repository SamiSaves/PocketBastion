# PocketBastion

PocketBastion runs the OpenCode web UI on Fedora CoreOS, so you can code from
any device on your own network, including your phone. The OS is disposable; the
repos, OpenCode sessions, caches and configs on `/mnt/state` survive a rebuild.

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

No key? `ssh-keygen -t ed25519 -f ~/.ssh/pocketbastion -C pocketbastion`, then
paste `~/.ssh/pocketbastion.pub`.

### 2. Create your server & connect

Each guide covers its prerequisites, creating the server, and connecting to it:

- [Raspberry Pi 4](docs/raspberry-pi.md) — the real thing
- [Local mock VM](docs/local.md) — the same image on KVM, for trying changes first

### 3. Post-install setup

SSH in with `ssh core@<the SERVER_HOST from deploy.env>` (`make local-ssh` does
this for the mock VM). Everything below is on `/mnt/state` and survives a
reflash.

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

**Authenticate a provider** with an interactive login (e.g. GitHub Copilot's
device flow):

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
reflash:

```bash
OPENCODE_EXTRA_PORTS="3000 5173 8000-8010"
```

These are also exactly the ports the firewall opens to `TRUSTED_CIDRS` — plus
SSH, and nothing else.

Start the server bound to `0.0.0.0` (not the host's address, which the container
can't see):

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

### Git access

Each repo gets its own deploy key, generated on the box and never leaving the
state disk. Works with any SSH git host (github.com, gitlab.com, self-hosted).
Access is per-repo and explicit — adding a repo is a deliberate step:

```bash
make repo-add REPO=git@github.com:owner/name.git
make repo-list
make repo-remove NAME=github-com-owner-name              # keeps the checkout
make repo-remove NAME=github-com-owner-name PURGE=1      # also deletes it
```

`repo-add` pauses while you register the printed public key on the repo (as a
deploy key), then verifies by cloning. github.com's host key is pinned in the
script; for any other forge it prints that forge's SSH fingerprint for you to
check against their published one, once. The container gets the per-repo deploy
key directly. Every configured key is in the container, so a compromised agent
has push access to every repo you have added — each `repo-add` widens that.

## Managing the server

`SERVER_HOST` in `deploy.env` decides where these connect; override it for a
single command with `SERVER_HOST=192.168.1.42 make repo-list`. `make help` lists
every target.

## How the config is built

One entry point, `config/butane/pocketbastion.bu`: the `core` user, sshd
hardening, the OpenCode container and its build, git setup, the firewall script,
zram, and the microSD partition layout — plus the scripts and units it pulls in
from `config/butane/files/`. `make ignition` substitutes `${VARS}` from
`deploy.env` into it and compiles it with Butane `--strict`.

The mock VM boots this same output, unmodified. Nothing branches on "am I a
VM" — that is what makes it worth testing on.

## Testing

```bash
make validate       # shellcheck, systemd-analyze, render
make local-up       # boot the mock and try it for real
```

Runtime behaviour is checked by running the mock. `make local-up` reflashes it
through the real `scripts/rpi/flash.sh`, so every rebuild also exercises
`--save-partlabel` and verifies the state partition did not move — the failure
that would otherwise cost you the data on a real card.

## Security notes

- The `core` user has a **public, default console password** (`space-depend-south`)
  for break-glass only. Change it on your first console login; sshd is key-only,
  so it is never usable over the network.
- The render refuses an empty `TRUSTED_CIDRS`, `0.0.0.0/0` or `0/0`;
  `firewall.env` emptied by hand afterwards locks the box down, but a hand-edited
  `0.0.0.0/0` there is applied as written — the render is the only gate on it.
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

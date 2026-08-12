# PocketBastion

PocketBastion runs an Orca runtime server on Fedora CoreOS, so you can code from
any device on your own network, including your phone. The OS is disposable; the
repos, Orca state, caches and configs on `/mnt/state` survive a rebuild.

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
| Break-glass | None — a serial console shows the boot, but there is no login |

The render **refuses** to produce a config without `TRUSTED_CIDRS` and rejects
`0.0.0.0/0`. Clients pair with the box once and talk to it over an end-to-end
encrypted channel; nothing is relayed or tunnelled, so being on the network
remains the price of entry.

## Getting started

### 1. Configure `deploy.env`

```bash
cp deploy.env.example deploy.env
```

Fill in your SSH **public** key (private keys never enter this repo) and who may
reach the box:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"          # log in to the server
TRUSTED_CIDRS="192.168.1.0/24"                             # who may reach it
```

No key? `ssh-keygen -t ed25519 -f ~/.ssh/pocketbastion -C pocketbastion`, then
paste `~/.ssh/pocketbastion.pub`.

### 2. Create your server & connect

Each guide covers its prerequisites, creating the server, and connecting to it:

- [Raspberry Pi 4](docs/raspberry-pi.md) — the real thing
- [Local mock VM](docs/local.md) — the same image on KVM, for trying changes first

### 3. Post-install setup

SSH in with `ssh core@<the box's address>` (`make local-ssh` does this for the
mock VM). Everything below is on `/mnt/state` and survives a
reflash.

**Pair a client.** The server prints an offer every time it starts:

```bash
journalctl --user -u orca | grep -A3 'Orca server ready'
```

Give the `orca://pair?code=…` URL to a desktop Orca, or open the printed browser
URL from any device on the network:

```bash
orca environment add --name pocketbastion --pairing-code 'orca://pair?code=…'
```

The credential lands on `/mnt/state`, so it survives reboots and reflashes. The
same offer is reprinted until someone claims it.

**Sign an agent in** from inside the container, so Orca registers the account on
the box:

```bash
podman exec -it orca orca account add --agent claude     # or: --agent codex
```

Orca points agents at its own managed credential store, so a bare `claude login`
authenticates plain terminals only, not Orca's agent panes.

Provider API keys go in `/mnt/state/secrets/orca.env`, one per line
(`ANTHROPIC_API_KEY=…`). A managed account wins: Orca strips these from the
agent's environment when one is set. After editing that file:

```bash
systemctl --user restart orca
```

### Running a dev server

Only ports you list are published from Orca's container. Add them to
`ORCA_EXTRA_PORTS` in `deploy.env` (space-separated ports/ranges), then reflash:

```bash
ORCA_EXTRA_PORTS="3000 5173 8000-8010"
```

These are also exactly the ports the firewall opens to `TRUSTED_CIDRS` — plus
SSH, and nothing else.

Start the server bound to `0.0.0.0` (not the host's address, which the container
can't see):

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

### Git access

The box holds a single **fine-grained GitHub PAT**
([ADR 0001](docs/adr/0001-fine-grained-pat-replaces-deploy-keys.md)): repos
granted explicitly on github.com, Contents + Issues + Pull requests read/write.
Enter it once in Orca's terminal (web client → terminal); it lands on the state
disk and survives reflashes:

```bash
gh auth login          # paste the PAT
gh auth setup-git      # git over HTTPS uses gh as credential helper
git config --global user.name  "You"
git config --global user.email "you@example.com"
```

Adding a repo later is not a box operation at all: grant the PAT access on
github.com, then tell the agent to clone it under `/repos`. Revocation happens
on github.com too — revoke or narrow the PAT.

## Managing the server

The admin UI (`http://<the box's address>:8080`, `docs/admin-ui.md`) covers
status, pairing, logs and the admin password without SSH. `make help` lists the
laptop-side targets.

## How the config is built

One entry point, `config/butane/pocketbastion.bu`: the `core` user, sshd
hardening, the Orca container and its build, git setup, the firewall script,
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

- The `core` user has **no password**: a console or serial adapter gets you no
  login, SSH is key-only, and recovery from a lockout is a reflash — which keeps
  `/mnt/state`.
- The render refuses an empty `TRUSTED_CIDRS`, `0.0.0.0/0` or `0/0`;
  `firewall.env` emptied by hand afterwards locks the box down, but a hand-edited
  `0.0.0.0/0` there is applied as written — the render is the only gate on it.
- The box runs no VPN of its own, so it is only as isolated as the network you
  put it on. Client sessions are device-paired and end-to-end encrypted, and the
  box opens no outbound relay or tunnel to make itself reachable.
- The firewall filters inbound only. The container's outbound access is
  unrestricted: an agent inside it can reach your LAN and the internet.
- The git credential is a single fine-grained PAT, scoped on github.com to
  explicitly granted repos
  ([ADR 0001](docs/adr/0001-fine-grained-pat-replaces-deploy-keys.md)).

## TODO

- Improve security stance on the agent container, see if we can avoid it holding so many secrets (the GitHub PAT, agent credentials)
- See if we could host vscode server for better development experience
- Consider DNS for the Pi
- Consider custom web UI for managing the server

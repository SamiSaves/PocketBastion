# Admin UI

A web page for managing the box, replacing the `make` targets that shell in over
SSH. Reachable from a phone on the trusted network.

## Why

There is no overview of what the box is doing, and every management action
otherwise means SSH. The goal is a box whose happy path — first boot to working
agent — never needs a terminal on the laptop.

## The rule

> **Anything in `deploy.env` is build-time — changed by reflash.
> Anything on `/mnt/state` is runtime — changed on the box.**

| build-time (`deploy.env`, reflash) | runtime (`/mnt/state`) |
|---|---|
| `SSH_AUTHORIZED_KEY` | admin password (after first change) |
| `TRUSTED_CIDRS` | GitHub credential, git identity (Orca terminal) |
| `ADMIN_PORT`, `ORCA_EXTRA_PORTS` | repos (agent-cloned) |
| memory caps, `ZRAM_SIZE` | pairings, container state |
| `ADMIN_PASSWORD_HASH` (initial only) | `orca.env` (optional provider keys, SSH) |

No overlap, so there is never a question of which one wins. Flashing and
rendering stay on the laptop — that is the line, not a gap.

## Architecture

```
laptop                              box
──────                              ───
astro build ──► static HTML/CSS/JS
                       │
                 inlined in Ignition (≈30 KB budget)
                       │
                       ▼
              pbweb container ── rw ──► /mnt/state/admin
              (node:24-slim, uid 1000) ── ro ──► /run/pocketbastion
                       │                         (status file, pairing.env)
                       │ /run/pb-priv.sock  (root:pbweb 0660)
                       ▼
              pb-priv@.service ── one verb per connection, exits
                       ▲
              pb-status.timer ── root, writes agent-status.json each minute
```

**Astro is `output: 'static'`.** It runs on the laptop and emits files. No SSR,
no Node adapter on the box — that would be a permanent ~70 MB process.

**The runtime is the Orca image**, already built and on disk (`node:24-slim`).
A second Quadlet container from the same image costs no extra pull and no new
toolchain. ≈50 MB RSS while running.

**Updating the UI requires a reflash.** That is accepted: the assets are inlined
in the Ignition config, which is also why the built site has a size budget.

### The ~30 KB budget

Ignition is delivered on the Pi's boot partition, so there is no hard cap — but
keeping it small keeps it reviewable. Treat 30 KB of built output as the budget.

In practice that means **no client framework**. For a handful of pages, plain
HTML with a few `fetch` calls is the right answer anyway. (This is also why the
pairing screen shows a tappable link, not a QR: a QR encoder is ~10 KB of the
budget for a scan that pairing-on-the-phone never needs.)

## Privilege model

pbweb runs as uid 1000 in a container. It holds no privilege and cannot escalate
— no sudo, no setuid path, `NoNewPrivileges=yes`.

Everything it needs is a read-only mount, one writable mount, or the socket:

| needs | how |
|---|---|
| admin password hash | mount `/mnt/state/admin` (rw — password change) |
| auth + pairing status, checkouts, paired devices | mount `/run/pocketbastion` (ro) — the status file |
| restarts, logs, reset | the socket |

pbweb no longer mounts `/mnt/state/secrets`: with deploy keys gone it has no
business there, and the GitHub credential lives in Orca's `/data`, which pbweb
never sees.

### The root API

systemd listens on the socket. A connection spawns a **fresh root process** that
handles one verb and exits — nothing runs the rest of the time.

```
is-active orca
restart orca
logs <unit>          allowlist: orca; fixed line count, no other arguments
reset-pairing        delete orca-devices.json, restart orca
```

Four verbs. The web process never builds a command string — there is no
argument anywhere that becomes a shell command. If pbweb is fully compromised,
the attacker's entire capability is: restart Orca, read its recent logs, force
every device to re-pair.

Two rules keep it that way:

- **Validate on the root side.** pbweb's checks are for user feedback; the root
  side assumes every byte is hostile.
- **Adding a verb is a security review.** It stays a `case` statement so that
  this is realistic.

Not a sudoers allowlist, for two reasons: sudo is setuid, so pbweb would have to
retain the ability to gain privilege at all; and sudo does not cross the
container boundary, while a bind-mounted socket does.

### The status file

Status that would otherwise need a verb comes from a **root-written file**
instead: `pb-status.timer` runs a script every minute (and at boot) that writes
`/run/pocketbastion/agent-status.json`, mode 0644, containing only derived
facts — never a token:

- GitHub: the username line from gh's `hosts.yml`, or absent
- Claude / Codex: credential file exists or not
- git identity: `user.email` set in `/data/.gitconfig` or not
- the latest `orca_server_ready` line from Orca's journal — pairing offer,
  web client URL, or the failure reason
- the paired-device list, relayed from `orca-devices.json`. Not the planned ro
  single-file mount: `reset-pairing` deletes and Orca recreates the file, and a
  single-file bind mount keeps pointing at the deleted inode — pbweb would show
  the pre-reset list forever.
- checkouts under `/mnt/state/repos`, name + size. `du` belongs in a
  once-a-minute root timer, not in a page load walking `node_modules` on the
  microSD — so no repos mount either.

Up to a minute stale, which is fine for auth rows; after "restart Orca" the
pairing screen says so and refreshes. This is the file-over-socket pattern the
Quadlet's `ponytail:` note names — it keeps the root API small and pbweb out of
Orca's state.

## Login

A single admin password. Not a system account — `core` has no password at all
(see `pocketbastion.bu`), so there is nothing to authenticate against, and
adding one back would mean a root verb to check and change it.

**Initial value** comes from `ADMIN_PASSWORD_HASH` in `deploy.env`, generated by
`make admin-hash` (scrypt, via node's built-in `crypto.scrypt`). Rendered to
`/etc/pocketbastion/admin.hash`.

**Seeding**, on pbweb start:

```
/mnt/state/admin/admin.hash missing?  → copy /etc/pocketbastion/admin.hash in
present?                              → leave it alone
```

First flash seeds it; later reflashes do not clobber a password you changed.

**Changing it** (a screen): requires the current password, writes the state
copy, and invalidates every session including the caller's — if the change was
made out of suspicion, that is the behaviour you want, and logging back in once
is cheap.

**Recovery**: delete `/mnt/state/admin/admin.hash` over SSH and restart pbweb.
It reseeds from the rendered value. That is the reset path, and using it
requires SSH key access.

**Rate-limit the login.** See the threat notes below — a brute force can come
from inside the box.

## Screens

### Status

The headline screen, and the reason for the whole thing. Everything else is a
form; this is the part that makes invisible config visible.

| row | source | flags |
|---|---|---|
| Trusted networks | `/etc/pocketbastion/firewall.env` | — |
| Open ports | `firewall.env` | — |
| Admin password | `/mnt/state/admin/` | amber if still the rendered one |
| GitHub | status file | amber if not authed → points at the setup guide |
| Claude / Codex | status file | amber if neither authed |
| git identity | status file | amber if unset |
| Repos | status file | name + size, informational |
| Memory / zram | `/proc/meminfo`, `/sys/block/zram0` | amber when tight |
| Load | `/proc/loadavg` | amber when high |
| Temperature | `/sys/class/thermal` | amber when hot; row absent on the VM |
| Containers | socket → `is-active` | red if not running |
| Disk on `/mnt/state` | `statvfs` | amber when low |

### Pairing

From the status file's ready-line. Shows, in this order:

1. **Web client URL** — tap to open Orca's browser client. Pairs at *runtime*
   scope: full capability, including creating and cloning projects. **On a
   fresh box, do this first** — the mobile app cannot create projects, so at
   least one must exist before it has anything to attach to.
2. **Pairing link** (`orca://pair?...`) — tap on the phone to pair the mobile
   app (*mobile* scope: restricted method allowlist).
3. **Paired devices** — from `orca-devices.json` (ro): name, created, last
   seen. The list is what makes an odd or forgotten device visible.
4. **Reset pairings** — the `reset-pairing` verb. There is no per-device revoke
   on a headless server (desktop-app only, upstream), so revocation is
   all-or-nothing: every device re-pairs against a fresh offer. That is the
   supported path and the right shape for "a phone was lost".

A new offer is minted only at startup, so "pair another device later" =
restart Orca (button on this screen), wait for the refresh.

Once every device is enrolled, `--no-pairing` in a dropin stops the box minting
offers; documented, not default.

### Logs

Recent lines from Orca's journal via the `logs` verb. Fixed line count. This is
what turns "Orca: red" from a dead end into a diagnosis without SSH.

### Password

The change form described under Login.

## One-time setup (Orca terminal)

Auth material never passes through the admin UI — it is entered once, in Orca's
own terminal (web client → terminal), and lands in `/data`, which survives
reflashes:

```bash
gh auth login          # paste the fine-grained PAT (see docs/adr/0001)
gh auth setup-git      # git clone/push over HTTPS uses gh as credential helper
git config --global user.name  "You"
git config --global user.email "you@example.com"
claude                 # and/or codex — interactive agent auth
```

The status screen's amber rows point here until each is done. Adding a repo
later is not a box operation at all: grant the PAT access on github.com, then
tell the agent to clone it.

## Bootstrap

The whole first-run story, no SSH:

1. Flash, open the admin UI, log in with the `deploy.env` password.
2. Pairing screen → **web client URL** → create or clone the first project,
   run the one-time terminal setup above.
3. Pairing screen → **pairing link** on the phone → mobile app attached.
4. Change the admin password.

## Ports

`ADMIN_PORT` is separate from the Orca publish list. Both reach the firewall
accept set; only Orca's reach the Quadlet's `PublishPort`.

```
firewall accept:  22, ADMIN_PORT, ORCA_PORTS
quadlet publish:  ORCA_PORTS
```

`ADMIN_PORT` must be >1024 so pbweb needs no `CAP_NET_BIND_SERVICE`. The render
rejects a collision with 22, 6768, or anything in `ORCA_EXTRA_PORTS` —
easy to hit by accident with ranges like `5173-5180`, and it fails as "the admin
UI is mysteriously the dev server" rather than as an error.

## Threat notes

The perimeter is the network's job: the Pi sits on its own VLAN with nothing
else on it, reached over the Unifi VPN. The box runs no VPN of its own.
`TRUSTED_CIDRS` is the whole in-box access control.

**The Orca container can reach the admin UI.** The input chain has
`iif "lo" accept`, and rootless pasta makes the container's outbound connections
originate in the host netns — so a connection to the box's own address arrives
over loopback and matches that rule, bypassing `TRUSTED_CIDRS`. Narrowing the
CIDRs does not close this.

That is consistent with the model — each service authenticates — but it means
**the admin password is the only barrier between a prompt-injected agent and the
admin UI.** Hence the rate limit. If it ever needs closing, `meta skuid 1000` in
the input chain does it.

**The Orca container can reach the socket too** (same uid as pbweb). Bounded by
the allowlist: the worst an agent can do through it is restart Orca, read its
own logs, or force every device to re-pair. Re-pairing is denial of
convenience, not exposure — a fresh offer only ever appears in the journal and
the admin UI, both out of the agent's reach. Give pbweb its own uid before any
verb whose blast radius is bigger than that.

Verify rather than trust the loopback claim; pasta's behaviour shifts between
podman versions:

```bash
podman exec orca curl -sv --max-time 2 http://<box-lan-ip>:<ADMIN_PORT>/
```

**Box-to-box:** with two PocketBastions on one VLAN, either one's agent can
reach the other's admin UI and SSH. Scoping `TRUSTED_CIDRS` to the VPN pool
rather than the VLAN closes that — a `deploy.env` change, no code.

**No TLS.** Plaintext HTTP on an isolated VLAN, so the admin password crosses in
the clear. The mitigating fact is that the Orca container cannot sniff it
(separate netns, no `CAP_NET_RAW`), which puts it outside the stated threat
model. Orca's own transport is end-to-end encrypted, so the admin UI is the only
thing on the wire in the clear. Tracked separately; see "Deferred".

**pbweb runs with SELinux type enforcement disabled.** systemd owns the pb-priv
listening socket, so reaching it needs `container_t` → `init_t` `connectto`,
which stock FCOS policy does not grant. The denial is `dontaudit`'d, so it
surfaces as a bare `EACCES` with no AVC in the log; relabelling the socket does
not help, because the block is on the connect rather than the file. Verified on
the mock VM at the socket's natural `var_run_t`: default `EACCES`,
`--security-opt label=disable` replies.

A policy module granting that permission would be worse — `container_t` covers
the Orca container, so it would give the agent a channel to every
socket-activated unit on the box. Disabling it for this one container leaves
Orca confined, and pbweb is still held by its uid, its mounts and its memory
cap. The SELinux-native alternative is in the Quadlet's `ponytail:` note — and
the status file is that pattern, already adopted for reads.

## Deleted with the deploy-key machinery

Superseded by the fine-grained PAT (see `docs/adr/0001`): `repo-add.sh`,
`repo-list.sh`, `repo-remove.sh` and their `make` targets, the `.meta` files
and known_hosts pinning, `git-setup.{sh,service}` (its allowlist entry with
it), the rendered gitconfig and `GIT_USER_NAME`/`GIT_USER_EMAIL` in
`deploy.env`, and the planned Repos and `orca.env` screens.

## Deferred

- **TLS via Let's Encrypt.** DNS-01 needs no inbound port and no static IP — an
  A record may point at a private address, and you always reach the box over the
  VPN. Dynamic DNS is a separate concern (the Unifi VPN endpoint, not this).
  Costs a domain, a zone-scoped API token on `/mnt/state`, `acme.sh` (pure
  shell, needs only curl and openssl — certbot is Python and Python is not on
  FCOS), and a timer. Own project.
- **First-login forced password change.** The amber status row nags meanwhile.
- **Firewall editing from the UI.** `TRUSTED_CIDRS` is build-time by the rule
  above, and it is the one setting that can lock you out.
- **Cockpit** as an optional layer for terminal, logs and metrics.
- **Reboot from the UI.** The socket is agent-reachable, so a reboot verb is an
  unauthenticated reboot for a prompt-injected agent. Arrives together with
  pbweb-own-uid work, or not at all — SSH covers it.
- **Per-device revoke.** Upstream limitation; reset-all is the supported path.
- **Machine account.** The escalation if PAT scoping ever chafes: a separate
  GitHub account invited per-repo, agent activity under its own identity.

## Build order

Phases 0–1 (privsep socket, hash generator, login, status screen) are built.

2. **Password change.** Smallest write action; closes the amber row.
3. **Status file.** `pb-status.{timer,service}` + script; `--json
   --mobile-pairing` on the Orca Exec; new status rows (auth, load, temp,
   repos). Verify the `orca-devices.json` path on the mock VM while here.
4. **Pairing screen.** Links, device list, restart + reset-pairing buttons —
   the two new verbs land with it.
5. **Logs screen.**
6. **Deletions.** Everything in "Deleted" above, plus dropping pbweb's
   `/mnt/state/secrets` mount.

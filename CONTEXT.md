# PocketBastion

A disposable Fedora CoreOS box (Raspberry Pi 4, mocked by a local VM) that runs
an Orca agent runtime; everything worth keeping lives on the state disk and
survives a reflash.

## Language

### The box

**Box**:
The running server — the Pi or the mock VM. Its OS is disposable; its identity
is the state disk.
_Avoid_: server, VM (except when specifically meaning the mock)

**Reflash**:
Rebuilding the box's OS from the rendered config. Destroys everything except
the state disk.
_Avoid_: rebuild, reinstall

**State disk**:
The persistent partition (`/mnt/state`). The only thing a reflash preserves.

**Build-time setting**:
A value in `deploy.env`, applied by reflash. Never changeable on the box.

**Runtime setting**:
A value on the state disk, changed on the box (admin UI or Orca terminal).
Never overwritten by a reflash after first seed.

**Trusted networks**:
The CIDRs allowed through the firewall — the box's entire access control.

### Agents and access

**Agent**:
The coding agent (Claude, Codex) running inside the Orca container.

**GitHub credential**:
The single fine-grained PAT the box holds, scoped on github.com to explicitly
granted repos. Replaces per-repo deploy keys.
_Avoid_: deploy key, token (unqualified)

**One-time setup**:
The terminal session in Orca that auths gh, git identity, and the agents.
Survives reflashes; done once per box lifetime.

### Admin UI

**Admin password**:
The single credential in front of the admin UI. Not a system account.

**Seed password**:
The admin password rendered from `deploy.env`; used until first change, then
never consulted again except by the SSH recovery path.

**Verb**:
One entry in the root API's allowlist — the entire privileged capability
available to the admin UI (and to anything else that reaches the socket).
_Avoid_: command, endpoint

**Status file**:
The root-written, secrets-free snapshot of box and agent state that the admin
UI reads. Derived facts only; up to a minute stale.

### Pairing

**Pairing offer**:
The startup-minted capability (a link) a device claims to enroll. Stable until
claimed; a fresh one requires an Orca restart.
_Avoid_: pairing code, QR

**Paired device**:
A device that has claimed an offer and holds its own credential. Each has a
scope.

**Runtime scope**:
Full capability on the Orca runtime — create, clone, and manage projects. What
the web client pairs at.

**Mobile scope**:
The restricted, mostly read capability the mobile app pairs at. Cannot create
projects.

**Web client**:
Orca's browser client, served by the box itself. The bootstrap tool: the only
paired client that can create the first project.

**Reset pairings**:
The revocation action: every paired device is forgotten and must re-pair. There
is no per-device revoke on a headless runtime.
_Avoid_: revoke (singular)

**Project**:
A directory *registered* with the Orca runtime. A directory on disk is not a
project until registered — and the mobile app can only see, never create, them.
_Avoid_: repo (for the Orca concept), workspace

# Architecture decision records

<!-- Template:
## ADR-NNN — Title

**Status:** Proposed | Accepted | Superseded

**Context:**
Why does this decision need to be made?

**Decision:**
What was decided?

**Consequences:**
What are the trade-offs?
-->

---

## ADR-001 — Use Fedora CoreOS as the base OS

**Status:** Accepted

**Context:**
We need a minimal, immutable OS that is easy to provision automatically and
dispose of regularly without losing application state.

**Decision:**
Use Fedora CoreOS. It ships with Podman, SELinux enforcing, and auto-updates
out of the box. Provisioning is handled by Ignition, which is a first-class
mechanism rather than a bolt-on.

**Consequences:**
- `rpm-ostree` is the only safe way to add packages; this keeps the OS layer
  thin and reproducible.
- Some tooling (e.g., `apt`) is unavailable; scripts must target Fedora/RPM
  conventions.

---

## ADR-002 — All services behind WireGuard, no public ports

**Status:** Accepted

**Context:**
Running a game dev server and an AI assistant on a public IP would expose them
to the internet unless carefully firewalled per application.

**Decision:**
Bind all application services to the WireGuard interface (`wg0`) only.
`firewalld` drops everything except WireGuard UDP port 51820.

**Consequences:**
- Every client (laptop, CI) needs a WireGuard peer config.
- No accidental exposure of half-configured services.

---

## ADR-003 — Podman Quadlet instead of Docker Compose

**Status:** Accepted

**Context:**
CoreOS ships with Podman. Docker Compose requires an extra daemon and is not
the natural fit for a systemd-based OS.

**Decision:**
Use Podman Quadlet (`.container` unit files under `/etc/containers/systemd/`).
Systemd manages the service lifecycle; Podman handles image pull and execution.

**Consequences:**
- No Docker socket; reduces attack surface.
- Quadlet syntax is declarative and maps directly to `podman run` flags.
- Slightly less ecosystem documentation than Docker Compose.

---

## ADR-004 — `/mnt/state` as the single persistent volume

**Status:** Accepted

**Context:**
CoreOS auto-updates and we want to be able to destroy and recreate the OS disk
at will. Application data must survive this.

**Decision:**
Mount a separate block device (local virsh volume or DigitalOcean Volume) at
`/mnt/state`. All stateful data lives here. The OS disk is ephemeral.

**Consequences:**
- Clean separation between OS and data.
- Backup strategy only needs to cover `/mnt/state`.
- VM recreation does not require a database dump or export step.

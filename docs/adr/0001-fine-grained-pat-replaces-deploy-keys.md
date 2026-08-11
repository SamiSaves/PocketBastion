# A fine-grained GitHub PAT replaces per-repo deploy keys

Deploy keys gave the box per-repo, revocable git access, but nothing else — and
Orca's value is working with issues and PRs, which deploy keys cannot see. We
replaced the whole apparatus (per-repo keygen, `.meta` files, known_hosts
pinning, `git-setup`, the repo-add/remove scripts) with a single **fine-grained
personal access token**: repos granted explicitly on github.com, Contents +
Issues + Pull requests read/write, ~90-day expiry, entered once via
`gh auth login` in Orca's terminal and persisted on the state disk.

The property that mattered about deploy keys — *adding a repo is a deliberate,
per-repo act* — survives: the grant list lives on github.com instead of on the
box, and the box never holds more access than was granted. What changed is
where revocation happens (revoke the PAT on github.com, not delete a key file)
and that machinery totaling several scripts and a boot service could be
deleted.

## Considered options

- **Broad OAuth (`gh auth login` device flow)** — rejected: grants `repo` scope
  over every repository the account touches.
- **Machine account** — a separate GitHub account invited per-repo; its token
  may be broad because the account is narrow, and agent activity gets its own
  identity in audit logs. Not taken now (extra account to maintain), but it is
  the documented escalation if PAT scoping chafes; switching is just re-authing.
- **Keep deploy keys alongside gh** — rejected: two credential systems for one
  box, and the keys still couldn't touch issues.

## Consequences

- Agent commits appear under the account owner's identity (the machine account
  fixes this if it ever matters).
- The PAT expires; renewal is mint-on-github.com + re-paste in the Orca
  terminal. The admin UI's status row surfaces a missing auth.
- Cloning uses HTTPS with `gh` as git credential helper — SSH keys, pinning,
  and known_hosts management are gone entirely.

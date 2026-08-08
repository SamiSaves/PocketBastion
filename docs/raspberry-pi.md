# Raspberry Pi 4

PocketBastion on a Raspberry Pi 4 on your own network. The OS lives on a microSD
and is disposable; `/mnt/state` shares the same card and survives every reflash.

`NETWORK_MODE=lan` exists for this: a home network usually already has a VPN, so
the Pi does not need to run a second one.

Before writing a card, try the change on the [local mock](local.md) — it boots
this same config through this same flasher.

## 1. What you need

| | |
|---|---|
| Board | **Raspberry Pi 4** (4 GB or better). Pi 5 has no U-Boot path and is not supported. |
| Card | 32 GB microSD minimum, 64 GB comfortable. High-endurance is worth it. |
| Network | **Ethernet.** Wi-Fi would need NetworkManager keyfiles in Ignition, which this config does not do. |
| Firmware | The Pi's **EEPROM must be updated first** — see below. |
| Host tools | `podman`, `sudo`, `jq`, `lsblk`, `sfdisk`, `rsync`, `envsubst` |

### Update the EEPROM first

Fedora CoreOS ships a FAT16 EFI system partition, and older Pi EEPROMs cannot
read one. A Pi with an old EEPROM shows nothing at all — no HDMI, no network —
which is indistinguishable from a dozen other faults.

Use `rpi-imager` to write the EEPROM updater to a throwaway card, boot it once,
then continue.

## 2. Configure

```bash
cp deploy.env.example deploy.env
```

Set your SSH public key, then choose the network mode. On a home LAN:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@host"

NETWORK_MODE=lan
TRUSTED_CIDRS="192.168.1.0/24"      # your LAN — nothing wider
SERVER_HOST=pocketbastion-rpi.lan   # or the DHCP address
```

`TRUSTED_CIDRS` is the entire access-control boundary in front of an AI agent
with a shell. The render refuses an empty value or `0.0.0.0/0`, and the firewall
falls back to a full lockdown if it is ever emptied by hand afterwards.

To have the Pi run its own WireGuard instead, set `NETWORK_MODE=wireguard` and
fill in the bootstrap peer as described in [wireguard.md](wireguard.md).

Want the mock on a different mode than the Pi? Keep `deploy.env` for the Pi,
copy it to `deploy.vm.env`, and point the mock at the copy:

```bash
DEPLOY_ENV=deploy.vm.env make local-up
```

### Tune for 4 GB of RAM and a flash card

```bash
OPENCODE_MEMORY_MAX=2g
OPENCODE_MEMORY_SWAP=3g
ZRAM_SIZE=1024
SWAPFILE_SIZE=                # leave EMPTY
```

`SWAPFILE_SIZE` writes `/var/swapfile` to the microSD, and swapping to flash is
the fastest way to wear a card out. `ZRAM_SIZE` gives compressed swap in RAM
instead, at no cost in writes.

## 3. Flash

```bash
# Find the device — do not assume, it moves between reboots
lsblk -o NAME,SIZE,TYPE,LABEL,MOUNTPOINT

# Desktops automount SD cards; the script refuses while anything is mounted
udisksctl unmount -b /dev/sdX1

make rpi-flash DEVICE=/dev/sdX
```

`make rpi-flash` re-renders the Ignition config every time, so it re-validates
`deploy.env` before writing anything.

The first run creates no state partition — Ignition does that on first boot.
Every run after preserves it and verifies afterwards that it is still at the
same sector; if it moved or vanished, the script fails and tells you not to
reboot.

Before writing, it checks that the device is a whole disk (or a loop device,
which is how the mock VM's image is flashed), that nothing on it is mounted, and
it prints the layout and makes you type the device path back before it starts.

### First boot

Allow 3–5 minutes: it partitions the card, creates the state filesystem, grows
root, then builds the OpenCode container image.

Find it on the network (hostname `pocketbastion-rpi`) and `ssh core@<ip>`.

## 4. One-time setup

Everything here lives on `/mnt/state` and survives reflashes.

**Set an OpenCode server password.** In `lan` mode the UI is plaintext HTTP on
your LAN, so it is the only credential in front of an agent with a shell.

```bash
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$(openssl rand -base64 24)" \
  > /mnt/state/secrets/opencode.env
chmod 600 /mnt/state/secrets/opencode.env
systemctl --user restart opencode.service
```

Add provider keys to the same file, one per line (`ANTHROPIC_API_KEY=…`). For
interactive logins: `podman exec -it opencode opencode auth login`.

## 5. Day-to-day

```bash
make repo-add REPO=git@github.com:owner/name.git
```

To change anything in `deploy.env`, re-flash. Repos, sessions, caches, secrets
and deploy keys are all on `/mnt/state` and come back untouched.

## 6. Two things that must not change

### `size_mib: 16384` for root

In `config/butane/pocketbastion.bu`. Immutable after the first flash. On a
reflash `--save-partlabel` pins `state` at its original offset while Ignition
re-grows root to the same end sector. Change the number and the resize collides
with the partition holding your data.

### The `state` partition omits `size_mib`

`size_mib: 0` and an omitted `size_mib` look equivalent but are opposites:

| | behaviour |
|---|---|
| `size_mib: 0` | Ignition recomputes a concrete sector count against the **current** geometry, then requires an exact match. |
| omitted | Ignition adopts the **existing** size, so the spec always matches. Nothing is recomputed, nothing moves. |

The geometry is not stable across a reflash — a first boot has the GPT repaired
by `coreos-gpt-setup`, a reflash has it written by coreos-installer — and on a
64 GB card the two disagree. Under `size_mib: 0` that aborts the disks stage in
the initramfs, before networking, and the Pi never appears on the LAN.

Omitting it also makes the config card-agnostic: with no state partition present
the partition simply fills the remaining space, on any size of card.

## 7. If it does not boot

If Ignition fails, FCOS drops to a dracut emergency shell in the initramfs,
before networking — so the host never appears on the network at all, and
"nothing on the router" is ambiguous between EEPROM, firmware, drivers and
Ignition.

1. Power-cycle once and wait 5 minutes. First boots are slow.
2. Confirm the EEPROM was updated (§1). Most common cause by far.
3. Get a USB-to-TTL serial adapter (~€3). Fedora's `config.txt` already sets
   `enable_uart=1`, so GPIO pins 8/10 at 115200 turn every silent failure into a
   readable one.
4. Isolate boot from partitioning: render a variant of `pocketbastion.bu`
   without the `storage.disks` and `storage.filesystems` stanzas. If that
   appears on the network, the problem is Ignition; if not, it is
   firmware/EEPROM/drivers. The [mock](local.md) rules Ignition in or out
   without touching the Pi at all.

## 8. Known gaps

| | |
|---|---|
| ESP vs `bootupd` | Untested whether an `rpm-ostree upgrade` preserves the U-Boot files added to the ESP. |
| microSD wear | npm installs, git clones and caches all land on flash. Mitigated by `noatime` and by leaving `SWAPFILE_SIZE` empty. A USB SSD is the real answer. |
| Wi-Fi | Not supported; needs NetworkManager keyfiles in Ignition. |

## 9. Reference

- FCOS on Pi 4: <https://docs.fedoraproject.org/en-US/fedora-coreos/provisioning-raspberry-pi4/>
- `coreos-installer install`: <https://coreos.github.io/coreos-installer/cmd/install/>
- Podman Quadlet: <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>

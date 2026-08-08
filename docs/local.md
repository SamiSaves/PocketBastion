# The local mock

A KVM VM that stands in for the Raspberry Pi. It is not a lookalike: it boots
the **same** Ignition config, written by the **same** `scripts/rpi/flash.sh`,
onto a disk image partitioned the same way. Try a `deploy.env` or Butane change
here before you write a card.

What it does not cover, and never will:

| | |
|---|---|
| Architecture | The mock is your host's (x86_64); the Pi is aarch64. Native modules and prebuilt binaries can differ. |
| Boot path | No U-Boot, no EEPROM, no `config.txt`. The mock boots through the VM firmware. |
| Storage | A sparse file on your SSD, not a microSD. Nothing here will tell you about card wear or speed. |

Everything above the bootloader — partitioning, the state filesystem, the
firewall, the OpenCode container, git access — is the real thing.

## Prerequisites

```bash
./scripts/local/prereqs.sh   # prints the install command if anything is missing
```

No image download and no libvirt pool setup: `make local-up` fetches the FCOS
metal image itself (~1 GB, cached in `images/`) and writes the disk directly.

## Create it

`deploy.env` (see the [README](../README.md)) holds your keys. The mock sits on
libvirt's network, not your LAN, so `TRUSTED_CIDRS` has to say so:

```bash
TRUSTED_CIDRS="192.168.122.0/24"
```

Then:

```bash
make local-up
```

If the Pi's `deploy.env` says something else, keep it and give the mock a copy:

```bash
DEPLOY_ENV=deploy.vm.env make local-up
```

First run allocates a sparse 64 GB image, flashes it and boots. Allow 3–5
minutes for first boot: it creates the state filesystem, grows root, then builds
the OpenCode container image.

```bash
VM_DISK_GB=32 make local-up          # smaller image (first run only)
RAM_MB=2048 VCPUS=2 make local-up    # trim if the host is small
```

The default is 4 GB of RAM and a 64 GB disk because the Pi it mocks is a 4 GB
board — memory limits and disk pressure behave the same way. Root is pinned at
16 GiB by the config and state takes the remainder, so images below 24 GB are
refused.

## Connect

The mock's address is DHCP-assigned by libvirt, so `make local-ssh` looks it up
each time rather than reading `SERVER_HOST` (which points at the real box):

```bash
make local-ssh
make local-ip      # the address itself, e.g. for `make repo-add`
```

If SSH does not answer, `make local-console` works without any network.

Then continue with **Post-install setup** in the [README](../README.md).

## Managing the VM

```bash
make local-up           # flash and boot (reflash if it already exists)
make local-console      # serial console (break-glass, no network needed)
make local-ip           # the VM's libvirt address
make local-ssh          # SSH in
make local-down         # remove the VM, keep its disk image
make local-wipe-state   # delete the disk image entirely (DATA LOSS)
```

## Re-running local-up is a reflash

The disk image is the mock's microSD card. `make local-up` on an existing image
runs `coreos-installer --save-partlabel state` against it exactly as a Pi
reflash does: the OS is replaced, `/mnt/state` survives, and the script then
verifies the state partition is still at the same sector and aborts if it moved.

That makes the everyday "try a change" loop double as the test for the one
failure that costs real data on a real card. `make local-wipe-state` throws the
image away so the next `make local-up` is a **first** flash instead — the other
path worth exercising after a change to the disk layout.

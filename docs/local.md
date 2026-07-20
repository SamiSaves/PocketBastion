# Local (KVM/libvirt) setup

Creating and managing a local VM. Do the [WireGuard setup](wireguard.md) first —
your public key goes into `deploy.env` before the VM exists.

## Prerequisites

Check tools and libvirt/kvm group membership, then do the one-time setup:

```bash
./scripts/local/prereqs.sh   # prints the install command if anything is missing
./scripts/local/setup.sh     # creates the libvirt storage pool
```

Download the Fedora CoreOS QEMU image where the VM expects it:

```bash
# https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64
# Bare Metal & Virtualized → QEMU (qcow2.xz)
xz -d fedora-coreos-*.qcow2.xz
sudo mv fedora-coreos-*.qcow2 /var/lib/libvirt/images/fedora-coreos-44.qcow2
```

## Create the VM

`deploy.env` (see the [README](../README.md)) holds your keys. Then:

```bash
make local-up        # renders Ignition and boots the KVM VM
```

## Connect your tunnel

The tunnel isn't up yet, so read the server's public key from the serial console:

```bash
make local-console
# then: passwd; sudo cat /mnt/state/wireguard/server_public.key; Ctrl-] to exit
```

Get the endpoint (the VM's LAN IP):

```bash
make local-ip
```

Paste both into your tunnel config and bring it up — see
[WireGuard setup](wireguard.md#3-write-your-tunnel-config). Once the tunnel is up,
`make wg-server-pubkey` fetches the key over SSH instead of the console.

Then continue with **Post-install setup** in the [README](../README.md).

## Managing the VM

```bash
make local-up           # create the VM
make local-console      # serial console (break-glass, no tunnel needed)
make local-ip           # print the VM's LAN IP
make local-ssh          # SSH in over the tunnel
make local-down         # destroy the VM, keep the state disk
make local-wipe-state   # permanently delete the state disk (DATA LOSS)
```

The OS is disposable: `make local-down` then `make local-up` reuses the state
disk (keys, peers, repos), so the VM keeps the same WireGuard identity.

# WireGuard setup

Every service (SSH, the OpenCode UI, dev servers) is reachable **only** through
the tunnel, so you set up your device first — its public key is baked into the
image before the VM exists. The network is `10.44.0.0/24`; the server is
`10.44.0.1`.

## 1. Create your keypair

Keep your keys in your own config dir (there's no per-user WireGuard dir like
`~/.ssh`, and `/etc/wireguard` is root-owned):

```bash
mkdir -p ~/.config/wireguard && chmod 700 ~/.config/wireguard
umask 077   # new files owner-only
wg genkey | tee ~/.config/wireguard/pocketbastion.key | wg pubkey \
  > ~/.config/wireguard/pocketbastion.pub
```

This writes your **private** key to `pocketbastion.key` (never leaves this
machine) and your **public** key to `pocketbastion.pub`.

## 2. Configure `deploy.env`

Here you pick this device's VPN address and hand over your public key:

```bash
cp deploy.env.example deploy.env
cat ~/.config/wireguard/pocketbastion.pub   # paste as WG_BOOTSTRAP_PUBKEY
```

```bash
WG_BOOTSTRAP_PUBKEY=<pocketbastion.pub contents>
WG_BOOTSTRAP_IP=10.44.0.2                       # this device's VPN address, unique in 10.44.0.0/24
```

## 3. Write your tunnel config

Create `~/.config/wireguard/pocketbastion.conf`:

```ini
[Interface]
Address    = 10.44.0.2/24            # same as WG_BOOTSTRAP_IP in deploy.env
PrivateKey = abc...123=              # pocketbastion.key contents (inline, no file path)

[Peer]
PublicKey           = xyz...789=     # server public key — filled in later
Endpoint            = 1.2.3.4:51820  # server IP — filled in later
AllowedIPs          = 10.44.0.0/24
PersistentKeepalive = 25
```

The `PublicKey` and `Endpoint` placeholders come from the server once it exists;
the local/DO deploy steps tell you where to get them.

## Bringing the tunnel up

```bash
sudo wg-quick up ~/.config/wireguard/pocketbastion.conf
sudo wg-quick down ~/.config/wireguard/pocketbastion.conf
```

`sudo` is needed because `wg-quick` creates a network interface and edits
routing — the config itself stays in your home dir.

## Adding more devices

Give each device a unique address in `10.44.0.0/24` (the server is `.1`, this
device is `.2`, so the next one is `.3`, and so on). Generate the keypair **on
the device** — `wg genkey` per step 1 on a laptop, or the WireGuard app on a
phone (it makes the keypair and shows the public key) — then register only its
**public** key:

```bash
make wg-add-peer PEER=phone IP=10.44.0.4 PUBKEY=<device public key>
```

The device's private key never leaves the device.

## Troubleshooting

- **Can't connect after a rebuild.** Recreating the VM may give it a new IP;
  update `Endpoint` in your `.conf`. Your keys don't change.
- **No handshake.** Confirm the server is reachable on UDP `51820` and that your
  `Address` matches the peer registered on the server.
- **Locked out.** If the tunnel is broken you can't SSH in — use the serial
  console, log in as `core`, and check `sudo wg show`.
- **Invalid key.** WireGuard keys are 44-char base64 ending in `=`; a truncated
  paste is the usual cause.

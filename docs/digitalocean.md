# DigitalOcean setup

Creating and managing the droplet. Do the [WireGuard setup](wireguard.md) first
— your public key goes into `deploy.env` before the droplet exists.

## Prerequisites

Install [Terraform](https://developer.hashicorp.com/terraform/install) and export
your DigitalOcean API token (never put it in a file):

```bash
export TF_VAR_do_token=<your DigitalOcean API token>
```

## Import the CoreOS image

DigitalOcean doesn't ship Fedora CoreOS, so import it once as a **custom image**.
Download the DigitalOcean image (`qcow2.gz`) from the
[Fedora CoreOS download page](https://fedoraproject.org/coreos/download?stream=stable&arch=x86_64)
and upload it under **Manage → Backups & Snapshots → Custom Images** in the DO
control panel, in the region you'll deploy to.

Once it finishes processing, grab its **numeric ID** for `coreos_image_slug`:

```bash
# with curl
curl -sX GET "https://api.digitalocean.com/v2/images?private=true" \
  -H "Authorization: Bearer $TF_VAR_do_token" | jq -r '.images[] | "\(.id)\t\(.name)"'

# or with doctl
doctl compute image list-user --format ID,Name
```

## Configure `deploy.tfvars`

`deploy.env` (see the [README](../README.md)) holds your keys; `deploy.tfvars`
holds the droplet spec:

```bash
cp deploy.tfvars.example deploy.tfvars
```

```bash
coreos_image_slug = <custom CoreOS image ID>   # numeric ID from "Import the CoreOS image"
region            = ams3                        # must match the image's region
droplet_size      = s-2vcpu-2gb
```

## Create the droplet

DigitalOcean requires an SSH key on password-less images, so `make tf-apply`
registers your `deploy.env` public key (`SSH_AUTHORIZED_KEY`) in DO automatically
— there's no separate DO key to create or manage.

```bash
make ignition-do
make tf-apply        # uses ./deploy.tfvars + deploy.env SSH key
```

## Connect your tunnel

The tunnel isn't up yet, so read the server's public key from the DO **Recovery
Console** (also your break-glass path if WireGuard ever fails). The agent-based
"Droplet Console"/"Web Console" doesn't work on CoreOS, so use the **Recovery
Console**. Log in as `core` with the default password **`space-depend-south`**,
change it, then read the key:

```bash
passwd                                          # set your own password
sudo cat /mnt/state/wireguard/server_public.key
```

> The default password only works on the Recovery Console (behind your DO account login);
> SSH is key-only and WireGuard-only, so it's never reachable from the internet.

Get the endpoint (the droplet's public IP):

```bash
cd terraform/digitalocean && terraform output wireguard_endpoint
```

Paste both into your tunnel config and bring it up — see
[WireGuard setup](wireguard.md#3-write-your-tunnel-config). Once the tunnel is up,
`make wg-server-pubkey` fetches the key over SSH instead of the console.

Then continue with **Post-install setup** in the [README](../README.md).

## Managing the droplet

```bash
make tf-plan            # preview droplet changes
make tf-apply           # apply changes (rebuilds reuse the state Volume)
make tf-destroy         # destroy the droplet (state Volume is preserved)
make wg-server-pubkey   # fetch the server WireGuard key over the tunnel
```

The OS is disposable: destroy and recreate the droplet and the state Volume
(keys, peers, repos) is preserved (`prevent_destroy`), so a rebuild reuses the
same WireGuard identity. A rebuilt droplet gets a new public IP, so clients
update their `Endpoint` (not their keys); a DO Reserved IP avoids even that. The
`core` password currently needs resetting after each recreate.

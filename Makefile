.PHONY: help ignition-local ignition-rpi validate \
        local-up local-down local-ip local-ssh local-console local-wipe-state \
        rpi-flash \
        wg-server-pubkey wg-add-peer \
        repo-add repo-list repo-remove \
        clean

BUTANE_IMAGE := quay.io/coreos/butane:release
VM_NAME      := pocketbastion-local
DEPLOY_ENV   := $(abspath deploy.env)

# Where the management targets connect. An environment variable wins; otherwise
# deploy.env; otherwise each script falls back to the WireGuard address.
SERVER_HOST ?= $(shell . $(DEPLOY_ENV) 2>/dev/null; printf '%s' "$$SERVER_HOST")
export SERVER_HOST

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition-local: ## Render local Ignition config from Butane (injects SSH key)
	@bash scripts/render-ignition.sh local

ignition-rpi: ## Render Raspberry Pi Ignition config from Butane
	@bash scripts/render-ignition.sh rpi

# ── Validation ──────────────────────────────────────────────────────────────

validate: ## Validate scripts and configs
	@./scripts/validate.sh

# ── Local VM lifecycle ───────────────────────────────────────────────────────

local-up: ignition-local ## Render Ignition and create local KVM VM
	@./scripts/local/create-vm.sh

local-down: ## Destroy local KVM VM (preserves state disk)
	@./scripts/local/destroy-vm.sh

local-wipe-state: ## Permanently delete the local state disk (DATA LOSS — prompts for confirmation)
	@./scripts/local/wipe-state.sh

local-ip: ## Print local VM IP address
	@./scripts/local/ip.sh

local-ssh: ## SSH into local VM
	@./scripts/local/ssh.sh

local-console: ## Open serial console for local VM
	@./scripts/local/console.sh

# ── Raspberry Pi 4 ───────────────────────────────────────────────────────────

rpi-flash: ## Flash FCOS + U-Boot to a microSD, preserving /mnt/state  (DEVICE=/dev/sdX)
	@./scripts/rpi/flash.sh "$(DEVICE)"

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove generated Ignition files
	@rm -f config/ignition/*.ign
	@echo "Cleaned generated Ignition files."

# ── WireGuard ────────────────────────────────────────────────────────────────
# Only meaningful when NETWORK_MODE is wireguard.

wg-server-pubkey: ## Fetch server WireGuard public key from VM → secrets/wireguard/server.public
	@scripts/wg-server-pubkey.sh

wg-add-peer: ## Register a peer's device-generated public key  (PEER=phone IP=10.44.0.4 PUBKEY=<key>)
	@scripts/wg-add-peer.sh

# ── GitHub repositories ──────────────────────────────────────────────────────

repo-add: ## Grant the VM access to a repo  (REPO=git@host:owner/name.git)
	@scripts/repo-add.sh "$(REPO)"

repo-list: ## List repos the VM has git access to
	@scripts/repo-list.sh

repo-remove: ## Revoke the VM's access to a repo  (NAME=host-owner-name [PURGE=1])
	@scripts/repo-remove.sh "$(NAME)" $(if $(filter 1 true yes,$(PURGE)),--purge,)

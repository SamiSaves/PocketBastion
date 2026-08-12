.PHONY: help ignition validate admin-hash ui ui-dev \
        local-up local-down local-ip local-ssh local-console local-wipe-state \
        rpi-flash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition: ## Render the Ignition config from Butane (injects SSH key)
	@bash scripts/render-ignition.sh

admin-hash: ## Print an ADMIN_PASSWORD_HASH line for deploy.env (prompts)
	@bash scripts/admin-hash.sh

# ── Admin UI ─────────────────────────────────────────────────────────────────
# Astro, static output, built on the laptop: ui/dist is what gets inlined into
# the Ignition config. Nothing here ever runs on the box.

ui: ## Build the admin UI to ui/dist
	@cd ui && npm install --silent --no-audit --no-fund && npm run build
	@du -sh ui/dist | awk '{printf "  ui/dist: %s\n", $$1}'

ui-dev: ## Serve the admin UI with live reload (no box, no API)
	@cd ui && npm install --silent --no-audit --no-fund && npm run dev

# ── Validation ──────────────────────────────────────────────────────────────

validate: ## Validate scripts and configs
	@./scripts/validate.sh

# ── Raspberry Pi ─────────────────────────────────────────────────────────────

rpi-flash: ## Flash FCOS + U-Boot to a microSD, preserving /mnt/state  (DEVICE=/dev/sdX)
	@./scripts/rpi/flash.sh "$(DEVICE)"

# ── Local mock of the Pi ─────────────────────────────────────────────────────
# Same config, same flasher, on a loopback disk image. Try changes here first.

local-up: ## Flash and boot the mock VM (reflash if it exists; keeps /mnt/state)
	@./scripts/local/create-vm.sh

# Both || true: destroying a VM that is not there is a no-op, not a failure.
local-down: ## Remove the mock VM, keep its disk image
	@virsh --connect qemu:///system destroy pocketbastion-local 2>/dev/null || true
	@virsh --connect qemu:///system undefine pocketbastion-local 2>/dev/null || true

local-wipe-state: ## Permanently delete the mock's disk image (DATA LOSS — prompts for confirmation)
	@./scripts/local/wipe-state.sh

local-ip: ## Print the mock VM's address on the libvirt network
	@./scripts/local/ip.sh

# The address is DHCP-assigned, so it is looked up per call. Host keys are
# thrown away: the mock is reflashed constantly and its key changes.
local-ssh: ## SSH into the mock VM
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	  core@$$(./scripts/local/ip.sh)

local-console: ## Open serial console for the mock VM
	@echo "Exit with: Ctrl+]"
	@virsh --connect qemu:///system console pocketbastion-local

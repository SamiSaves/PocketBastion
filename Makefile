.PHONY: help ignition validate \
        local-up local-down local-ip local-ssh local-console local-wipe-state \
        rpi-flash \
        repo-add repo-list repo-remove \
        clean

# ?= so `DEPLOY_ENV=deploy.vm.env make repo-add` reads SERVER_HOST from the file
# it renders from. With := the env var lost and the target hit the wrong box.
DEPLOY_ENV   ?= $(abspath deploy.env)

# Where the management targets connect. An environment variable wins; otherwise
# deploy.env. Each script errors if it ends up empty.
SERVER_HOST ?= $(shell . $(DEPLOY_ENV) 2>/dev/null; printf '%s' "$$SERVER_HOST")
export SERVER_HOST

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition: ## Render the Ignition config from Butane (injects SSH key)
	@bash scripts/render-ignition.sh

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

local-down: ## Remove the mock VM, keep its disk image
	@./scripts/local/destroy-vm.sh

local-wipe-state: ## Permanently delete the mock's disk image (DATA LOSS — prompts for confirmation)
	@./scripts/local/wipe-state.sh

local-ip: ## Print the mock VM's address on the libvirt network
	@./scripts/local/ip.sh

local-ssh: ## SSH into the mock VM
	@./scripts/local/ssh.sh

local-console: ## Open serial console for the mock VM
	@./scripts/local/console.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove generated Ignition files
	@rm -f config/ignition/*.ign
	@echo "Cleaned generated Ignition files."

# ── GitHub repositories ──────────────────────────────────────────────────────

repo-add: ## Grant the box access to a repo  (REPO=git@host:owner/name.git)
	@scripts/repo-add.sh "$(REPO)"

repo-list: ## List repos the box has git access to
	@scripts/repo-list.sh

repo-remove: ## Revoke the box's access to a repo  (NAME=host-owner-name [PURGE=1])
	@scripts/repo-remove.sh "$(NAME)" $(if $(filter 1 true yes,$(PURGE)),--purge,)

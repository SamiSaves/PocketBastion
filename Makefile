.PHONY: help ignition ignition-local ignition-do validate \
        local-up local-down local-ip local-ssh local-console \
        vm-create vm-destroy ssh ip console clean

BUTANE_IMAGE := quay.io/coreos/butane:release
VM_NAME      := game-dev-coreos-local

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition: ignition-local ## Render local Ignition config (alias for ignition-local)

ignition-local: ## Render local Ignition config from Butane (injects SSH key)
	@bash scripts/render-ignition.sh local

ignition-do: ## Render DigitalOcean Ignition config from Butane
	@bash scripts/render-ignition.sh do

# ── Validation ──────────────────────────────────────────────────────────────

validate: ## Validate scripts and configs
	@./scripts/validate.sh

# ── Local VM lifecycle ───────────────────────────────────────────────────────

local-up: ignition-local ## Render Ignition and create local KVM VM
	@./scripts/local-create-vm.sh

local-down: ## Destroy local KVM VM (preserves state disk)
	@./scripts/local-destroy-vm.sh

local-ip: ## Print local VM IP address
	@./scripts/local-ip.sh

local-ssh: ## SSH into local VM
	@./scripts/local-ssh.sh

local-console: ## Open serial console for local VM
	@./scripts/local-console.sh

# Aliases for backwards compatibility
vm-create: local-up ## Alias for local-up
vm-destroy: local-down ## Alias for local-down
ssh: local-ssh ## Alias for local-ssh
ip: local-ip ## Alias for local-ip
console: local-console ## Alias for local-console

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove generated Ignition files
	@rm -f config/ignition/*.ign
	@echo "Cleaned generated Ignition files."

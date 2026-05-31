.PHONY: help ignition-local ignition-do validate vm-create vm-destroy ssh ip console clean

BUTANE_IMAGE := quay.io/coreos/butane:release
VM_NAME      := game-dev-coreos-local

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition-local: ## Render local Ignition config from Butane
	@echo "Rendering config/ignition/local.ign..."
	@podman run --rm -i $(BUTANE_IMAGE) \
		--pretty --strict < config/butane/local.bu \
		> config/ignition/local.ign
	@echo "Done."

ignition-do: ## Render DigitalOcean Ignition config from Butane
	@echo "Rendering config/ignition/digitalocean.ign..."
	@podman run --rm -i $(BUTANE_IMAGE) \
		--pretty --strict < config/butane/digitalocean.bu \
		> config/ignition/digitalocean.ign
	@echo "Done."

# ── Validation ──────────────────────────────────────────────────────────────

validate: ## Validate scripts and configs
	@./scripts/validate.sh

# ── Local VM lifecycle ───────────────────────────────────────────────────────

vm-create: ignition-local ## Create local KVM VM
	@./scripts/local-create-vm.sh

vm-destroy: ## Destroy local KVM VM
	@./scripts/local-destroy-vm.sh

# ── Access helpers ───────────────────────────────────────────────────────────

ssh: ## SSH into local VM
	@./scripts/local-ssh.sh

ip: ## Print local VM IP address
	@./scripts/local-ip.sh

console: ## Open serial console for local VM
	@./scripts/local-console.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove generated Ignition files
	@rm -f config/ignition/*.ign
	@echo "Cleaned generated Ignition files."

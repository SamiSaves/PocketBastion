.PHONY: help ignition-local ignition-do validate \
        local-up local-down local-ip local-ssh local-console local-wipe-state \
        wg-server-pubkey wg-add-peer \
        repo-add repo-list repo-remove \
        tf-plan tf-apply \
        harden-check \
        clean

BUTANE_IMAGE := quay.io/coreos/butane:release
VM_NAME      := opencode-dev-server-local
TF_DIR       := terraform/digitalocean
TFVARS       := $(abspath deploy.tfvars)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Ignition rendering ──────────────────────────────────────────────────────

ignition-local: ## Render local Ignition config from Butane (injects SSH key)
	@bash scripts/render-ignition.sh local

ignition-do: ## Render DigitalOcean Ignition config from Butane
	@bash scripts/render-ignition.sh do

# ── Validation ──────────────────────────────────────────────────────────────

validate: ## Validate scripts and configs
	@./scripts/validate.sh

harden-check: ## Runtime hardening checks against the live VM (phase 10)
	@./scripts/hardening-check.sh

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

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean: ## Remove generated Ignition files
	@rm -f config/ignition/*.ign
	@echo "Cleaned generated Ignition files."

# ── WireGuard ────────────────────────────────────────────────────────────────

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

# ── DigitalOcean (Terraform) ──────────────────────────────────────
# Both read the root ./deploy.tfvars. Set TF_VAR_do_token in your env first.

tf-plan: ## Terraform plan for DigitalOcean (uses ./deploy.tfvars)
	@cd $(TF_DIR) && terraform init -input=false && terraform plan -var-file="$(TFVARS)"

tf-apply: ## Terraform apply for DigitalOcean (uses ./deploy.tfvars)
	@cd $(TF_DIR) && terraform init -input=false && terraform apply -var-file="$(TFVARS)"

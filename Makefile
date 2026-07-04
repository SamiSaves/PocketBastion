.PHONY: help ignition-local ignition-do validate \
        local-up local-down local-ip local-ssh local-console local-wipe-state \
        wg-generate-keys wg-server-pubkey wg-add-peer wg-render-client \
        github-install-deploy-key github-test-access \
        clean

BUTANE_IMAGE := quay.io/coreos/butane:release
VM_NAME      := opencode-dev-server-local

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

wg-generate-keys: ## Generate WireGuard keypair for a peer  (PEER=laptop)
	@scripts/wg-generate-keys.sh "$(PEER)"

wg-server-pubkey: ## Fetch server WireGuard public key from VM → secrets/wireguard/server.public
	@scripts/wg-server-pubkey.sh

wg-add-peer: ## Add peer to VM WireGuard config  (PEER=laptop IP=10.44.0.2)
	@scripts/wg-add-peer.sh

wg-render-client: ## Render client WireGuard config  (PEER=laptop ENDPOINT=<vm-ip>)
	@scripts/wg-render-client.sh

# ── GitHub access ────────────────────────────────────────────────────────────

github-install-deploy-key: ## Generate a repo-scoped GitHub deploy key on the VM
	@scripts/github-install-deploy-key.sh

github-test-access: ## Test GitHub deploy-key auth from the VM (ssh -T git@github.com)
	@scripts/github-test-access.sh

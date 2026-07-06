DEPLOYMENT ?= ragchat
LOCATION   ?= eastus2
SEARCH_LOCATION ?= eastus
PARAMS     := infrastructure/main.bicepparam --parameters searchLocation=$(SEARCH_LOCATION)

RESOURCE_GROUPS := rg-ragchat-networking rg-ragchat-app rg-ragchat-ai rg-ragchat-monitoring

show = az deployment sub show -n $(DEPLOYMENT) -o json --query properties.outputs | jq -r --arg k "$(1)" '[to_entries[]|select(.key|ascii_downcase==($$k|ascii_downcase))][0].value.value'

APP_RG    ?= rg-ragchat-app
acr_name  = az acr list -g $(APP_RG) --query "[0].name" -o tsv
acr_login = az acr list -g $(APP_RG) --query "[0].loginServer" -o tsv

.DEFAULT_GOAL := help
.PHONY: help preflight format-infrastructure validate-infrastructure bootstrap-infrastructure \
        build-app build-ingest deploy-infrastructure seed ingest open-app open-dashboard \
        verify-infrastructure destroy-infrastructure 

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

# --- Infrastructure -----------------------------------------------------------

preflight: ## Check region has capacity for the models/services before deploying
	@LOCATION="$(LOCATION)" bash scripts/preflight.sh

format-infrastructure: ## Format the bicep templates in place
	az bicep format --file infrastructure/main.bicep

validate-infrastructure: ## Lint the bicep and preview changes (what-if) before deploying
	az bicep lint --file infrastructure/main.bicep
	az deployment sub what-if -n $(DEPLOYMENT) --location $(LOCATION) --parameters $(PARAMS)

bootstrap-infrastructure: ## First-time deploy: stands up all infra with placeholder images (creates the ACR)
	az deployment sub create -n $(DEPLOYMENT) --location $(LOCATION) --parameters $(PARAMS)

deploy-infrastructure: ## Deploy/update infra and point the app + job at the real images (run after build-app/build-ingest)
	REG=$$($(acr_login)); \
	[ -n "$$REG" ] || { echo "no ACR found in $(APP_RG) — run 'make bootstrap-infrastructure' first"; exit 1; }; \
	az deployment sub create -n $(DEPLOYMENT) --location $(LOCATION) --parameters $(PARAMS) \
	  --parameters appImage=$$REG/ragchat:v1 ingestImage=$$REG/ragchat-ingestion:v1

# --- Containers ---------------------------------------------------------------

build-app: ## Build & push the app image to ACR
	REG=$$($(acr_name)); \
	[ -n "$$REG" ] || { echo "no ACR found in $(APP_RG) — run 'make bootstrap-infrastructure' first"; exit 1; }; \
	az acr build -r $$REG -t ragchat:v1 ./app

# Rebuild + push ONLY the ingestion image (the write-path Job). For an ingestion-only fix: the Job
# already points at the mutable ragchat-ingestion:v1 tag, so this + `make ingest` ships it — no redeploy.
build-ingest: ## Build & push the ingestion image to ACR
	REG=$$($(acr_name)); \
	[ -n "$$REG" ] || { echo "no ACR found in $(APP_RG) — run 'make bootstrap-infrastructure' first"; exit 1; }; \
	az acr build -r $$REG -t ragchat-ingestion:v1 ./ingestion

# --- Data ---------------------------------------------------------------------

seed: ## Upload the sample documents to blob storage
	STORAGE_ACCOUNT=$$($(call show,STORAGE_ACCOUNT)) uv run --script scripts/seed.py

ingest: ## Run the ingestion job to index the seeded documents
	az containerapp job start -n $$($(call show,INGEST_JOB_NAME)) -g $$($(call show,APP_RESOURCE_GROUP))

# --- Open ---------------------------------------------------------------------

open-app: ## Open the deployed app in the browser
	open $$($(call show,APP_URL))

open-dashboard: ## Open the monitoring workbook in the Azure portal
	@TENANT=$$(az account show --query tenantId -o tsv); \
	ID=$$($(call show,WORKBOOK_ID)); \
	[ -n "$$ID" ] || { echo "no WORKBOOK_ID output — run 'make bootstrap-infrastructure' first"; exit 1; }; \
	open "https://portal.azure.com/#@$$TENANT/resource$$ID/workbook"

# --- Verify / teardown --------------------------------------------------------

verify-infrastructure: ## Check the live deployment is keyless and print its outputs (no secrets)
	@echo "storage allowSharedKeyAccess (want: false):"
	@az storage account show -n $$($(call show,STORAGE_ACCOUNT)) -g $$($(call show,APP_RESOURCE_GROUP)) \
	  --query allowSharedKeyAccess -o tsv
	@echo "deployment outputs (endpoints + names only — no secrets):"
	@az deployment sub show -n $(DEPLOYMENT) --query properties.outputs -o json

destroy-infrastructure: ## Delete all resource groups and purge soft-deleted resources
	@echo "About to DELETE these resource groups and everything in them:"; \
	for rg in $(RESOURCE_GROUPS); do echo "  - $$rg"; done; \
	read -p "Type the deployment name ('$(DEPLOYMENT)') to confirm: " ans; \
	[ "$$ans" = "$(DEPLOYMENT)" ] || { echo "aborted."; exit 1; }; \
	echo "deleting resource groups in parallel — waiting for completion (APIM can take ~30-45 min) ..."; \
	for rg in $(RESOURCE_GROUPS); do \
	  ( az group delete -n $$rg --yes >/dev/null 2>&1 && echo "  deleted $$rg" || echo "  $$rg not found — skipping" ) & \
	done; \
	wait; \
	echo "removing the sub-scope deployment record (metadata only) ..."; \
	az deployment sub delete -n $(DEPLOYMENT) 2>/dev/null || echo "  (deployment '$(DEPLOYMENT)' not found — skipping)"; \
	echo "purging soft-deleted resources matching '$(DEPLOYMENT)' (they reserve their global names until purged) ..."; \
	TAB="$$(printf '\t')"; \
	az apim deletedservice list --query "[?contains(name,'$(DEPLOYMENT)')].[name,location]" -o tsv 2>/dev/null | while IFS="$$TAB" read -r n l; do \
	  loc=$$(echo "$$l" | tr '[:upper:]' '[:lower:]' | tr -d ' '); \
	  echo "  purging APIM $$n ($$loc)"; az apim deletedservice purge --service-name "$$n" --location "$$loc" >/dev/null; \
	done; \
	az cognitiveservices account list-deleted --query "[?contains(name,'$(DEPLOYMENT)')].[name,location,id]" -o tsv 2>/dev/null | while IFS="$$TAB" read -r n l id; do \
	  loc=$$(echo "$$l" | tr '[:upper:]' '[:lower:]' | tr -d ' '); \
	  rg=$$(echo "$$id" | sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p'); \
	  echo "  purging AI account $$n ($$loc, $$rg)"; az cognitiveservices account purge --name "$$n" --resource-group "$$rg" --location "$$loc" >/dev/null; \
	done; \
	az keyvault list-deleted --query "[?contains(name,'$(DEPLOYMENT)')].[name,properties.location]" -o tsv 2>/dev/null | while IFS="$$TAB" read -r n l; do \
	  loc=$$(echo "$$l" | tr '[:upper:]' '[:lower:]' | tr -d ' '); \
	  echo "  purging Key Vault $$n ($$loc)"; az keyvault purge --name "$$n" --location "$$loc" >/dev/null; \
	done; \
	echo "teardown complete — RGs gone, ghosts purged. Safe to 'make bootstrap-infrastructure LOCATION=<region>' anywhere."

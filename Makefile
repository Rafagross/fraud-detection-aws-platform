# Makefile — fraud-detection-aws-platform
# Targets that require AWS credentials use the SSO profile defined in PROFILE.
# Targets that do not require credentials (validate, fmt) work offline.
#
# Usage:
#   make            → show this help
#   make validate   → static checks, no AWS credentials required
#   make plan       → terraform plan (requires active SSO session)
#   make apply      → apply the saved plan
#   make destroy    → destroy all platform resources (asks for confirmation)

ENV_DIR := terraform/envs/dev
TF      := terraform -chdir=$(ENV_DIR)
PROFILE ?= cloudops-portfolio

.DEFAULT_GOAL := help

.PHONY: help init fmt validate plan apply pre-destroy destroy

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: ## Initialise Terraform backend (requires AWS credentials)
	AWS_PROFILE=$(PROFILE) $(TF) init

fmt: ## Format all Terraform files in place
	terraform fmt -recursive ./terraform

fmt-check: ## Check formatting without modifying files (used in CI)
	terraform fmt -check -recursive ./terraform

validate: ## Static validation — no AWS credentials required
	$(TF) init -backend=false -reconfigure
	$(TF) validate
	@echo "✓ terraform validate passed"

plan: ## Generate and save an execution plan
	AWS_PROFILE=$(PROFILE) $(TF) plan -out=$(ENV_DIR)/tfplan

apply: ## Apply the saved plan from 'make plan'
	AWS_PROFILE=$(PROFILE) $(TF) apply $(ENV_DIR)/tfplan

pre-destroy: ## Delete Backup recovery points + deregister Golden AMIs before terraform destroy
	AWS_PROFILE=$(PROFILE) AWS_REGION=us-east-1 ./scripts/pre-destroy.sh

destroy: ## Destroy all platform resources (run make pre-destroy first)
	@printf "WARNING: this will destroy all cloudops-dev resources.\nRun 'make pre-destroy' first if you have not already.\nType 'yes' to continue: " && \
	  read confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	AWS_PROFILE=$(PROFILE) $(TF) destroy

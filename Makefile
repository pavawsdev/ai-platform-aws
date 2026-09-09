# =============================================================================
# AI Platform — developer and operator entry points.
# Every target here is also what CI runs, so "works locally" means something.
# =============================================================================
SHELL      := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV        ?= dev
REGION     ?= ap-south-1
PROJECT    ?= aiplat
SERVICES   := ai-gateway rag-service agent-service eval-service
TF_DIR     := infra/terraform/envs/$(ENV)
NAMESPACE  ?= ai-platform

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --------------------------------------------------------------- infra ------
.PHONY: bootstrap
bootstrap: ## One-time: create the Terraform state backend and OIDC roles
	cd infra/terraform/bootstrap && terraform init && \
	  terraform apply -var="project=$(PROJECT)" -var="region=$(REGION)"

.PHONY: infra-plan
infra-plan: ## terraform plan for ENV
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl && \
	  terraform plan -var-file=$(ENV).tfvars -out=tfplan

.PHONY: infra
infra: infra-plan ## terraform apply for ENV
	cd $(TF_DIR) && terraform apply tfplan

.PHONY: infra-output
infra-output: ## Write terraform outputs and render the Helm overlay
	cd $(TF_DIR) && terraform output -json > /tmp/tf-$(ENV).json
	python ops/python/render_helm_values.py --outputs /tmp/tf-$(ENV).json --environment $(ENV)

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the ENV cluster
	aws eks update-kubeconfig --name $(PROJECT)-$(ENV) --region $(REGION)

# --------------------------------------------------------------- gitops -----
.PHONY: gitops
gitops: ## Install Argo CD and apply the root application
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
	helm upgrade --install argocd argo/argo-cd --namespace argocd \
	  --create-namespace --version 7.7.11 --wait \
	  --set controller.replicas=2 --set repoServer.replicas=2
	kubectl apply -f deploy/argocd/projects/
	kubectl apply -f deploy/argocd/apps/root.yaml
	@echo "watch: kubectl -n argocd get applications -w"

.PHONY: argocd-password
argocd-password: ## Print the initial Argo CD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

# --------------------------------------------------------------- quality ----
.PHONY: test
test: ## Run unit tests for every service
	@for svc in $(SERVICES); do \
	  echo "=== $$svc ==="; \
	  (cd services/$$svc && PYTHONPATH=.:../../libs/platform_common \
	     python -m pytest tests -q -o addopts="" -o asyncio_mode=auto) || exit 1; \
	done

.PHONY: lint
lint: ## Lint Python, Terraform and Helm
	@for svc in $(SERVICES); do (cd services/$$svc && ruff check app tests); done
	terraform fmt -check -recursive infra/terraform
	@for v in deploy/helm/values/*.yaml; do helm lint deploy/helm/service --values $$v --strict; done

.PHONY: fmt
fmt: ## Auto-format everything
	@for svc in $(SERVICES); do (cd services/$$svc && ruff format app tests && ruff check --fix app tests); done
	terraform fmt -recursive infra/terraform

.PHONY: security
security: ## Run the full local security sweep
	trivy fs --severity CRITICAL,HIGH --exit-code 1 services/
	checkov -d infra/terraform --framework terraform --compact
	tfsec infra/terraform
	gitleaks detect --no-banner --redact
	semgrep --config .semgrep.yml --error services/

.PHONY: policy
policy: ## Render manifests and test them against Kyverno + Conftest
	@mkdir -p /tmp/rendered
	@for v in deploy/helm/values/*.yaml; do \
	  helm template test deploy/helm/service --values $$v > /tmp/rendered/$$(basename $$v); done
	kyverno apply policy/kyverno --resource /tmp/rendered --detailed-results
	cd $(TF_DIR) && terraform show -json tfplan > /tmp/tfplan.json 2>/dev/null || true
	conftest test --policy policy/opa /tmp/tfplan.json || true

# --------------------------------------------------------------- local ------
.PHONY: dev-up
dev-up: ## Start postgres+pgvector and redis locally
	docker compose -f docker-compose.dev.yaml up -d
	@sleep 4
	docker compose -f docker-compose.dev.yaml exec -T postgres \
	  psql -U aiplatform -d aiplatform -f /migrations/001_init.sql
	docker compose -f docker-compose.dev.yaml exec -T postgres \
	  psql -U aiplatform -d aiplatform -f /migrations/003_seed_dev.sql

.PHONY: dev-down
dev-down: ## Stop local dependencies
	docker compose -f docker-compose.dev.yaml down -v

.PHONY: build
build: ## Build all service images locally
	@for svc in $(SERVICES); do \
	  docker build -f services/$$svc/Dockerfile -t $$svc:local . ; done

# --------------------------------------------------------------- ops --------
.PHONY: seed
seed: ## Seed dev tenants and API keys
	kubectl -n $(NAMESPACE) exec -i deploy/rag-service -- \
	  psql "$$DATABASE_URL" -f /migrations/003_seed_dev.sql

.PHONY: smoke
smoke: ## End-to-end smoke test against the deployed gateway
	@bash scripts/smoke.sh

.PHONY: cost
cost: ## Weekly cost report and price-book reconciliation
	python ops/python/cost_report.py --days 7 --fail-on-drift

.PHONY: slo
slo: ## Check the SLO over the last hour
	python ops/python/check_slo.py \
	  --workspace-id "$$(cd $(TF_DIR) && terraform output -json observability | jq -r .amp_workspace_id)" \
	  --region $(REGION) --window 1h

.PHONY: dr-verify
dr-verify: ## Prove DR would meet its RPO right now
	python ops/python/dr_restore.py verify

.PHONY: dr-drill
dr-drill: ## Run a real DR restore and measure the RTO
	python ops/python/dr_restore.py drill --confirm

.PHONY: eval
eval: ## Run the evaluation gate against a prompt version
	cd services/eval-service && python -m app.cli \
	  --dataset $${DATASET:?set DATASET} --prompt-id $${PROMPT_ID:?set PROMPT_ID} \
	  --prompt-version $${VERSION:?set VERSION} --thresholds-from-registry \
	  --registry-dir ../../services/ai-gateway/config/prompts --fail-on-regression

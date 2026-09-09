# AI Platform on AWS — Production LLMOps & Agentic AI Platform

A multi-tenant AI platform that product teams ship on, built the way a platform
that carries customer data and a five-figure monthly model bill actually has to
be built: everything provisioned by Terraform, everything deployed by GitOps,
everything measured, bounded, governed and recoverable.

> This is deliberately **not** a "deploy an LLM on EKS" demo. The interesting
> problems here are cost attribution, guardrail layering, failure modes of a
> nondeterministic agent, error budgets on a system whose p99 is dominated by a
> third party, and proving after the fact what the platform did.

---

## Start here

| If you want to… | Read |
| --- | --- |
| Understand the design and the trade-offs | [`docs/architecture.md`](docs/architecture.md) |
| Build it end to end | [`docs/implementation.md`](docs/implementation.md) |
| See why each decision was made | [`docs/adr/`](docs/adr/) |
| Understand the security model | [`docs/security.md`](docs/security.md) |
| See the SLOs and error budget policy | [`docs/slo.md`](docs/slo.md) |
| Understand the money | [`docs/cost.md`](docs/cost.md) |
| Know what happens when the region dies | [`docs/dr.md`](docs/dr.md) |
| Fix something at 3am | [`docs/runbooks/`](docs/runbooks/) |

---

## What is here

```
infra/terraform/          14 modules, composed into one stack, 2 environments
  ├── bootstrap/          state backend + GitHub OIDC roles (run once)
  ├── modules/            vpc eks karpenter ecr rds-pgvector s3-datalake kms
  │                       iam-irsa alb-waf security-baseline observability
  │                       bedrock-guardrails backup-dr
  ├── stacks/platform/    the composition + per-service least-privilege IRSA
  └── envs/{dev,prod}/    thin wrappers; dev and prod run identical code

services/
  ├── ai-gateway/         auth, routing, breakers, guardrails, prompts,
  │                       semantic cache, token metering, audit
  ├── rag-service/        chunking, embeddings, hybrid retrieval (pgvector+FTS)
  ├── agent-service/      bounded multi-step agent, schema-validated tools
  └── eval-service/       LLM-judge eval harness + MLflow + the CI promotion gate

libs/platform_common/     shared telemetry (with redaction) and DB wiring

deploy/
  ├── helm/service/       ONE chart for every service + per-service values
  └── argocd/             app-of-apps, projects, ApplicationSet, addons,
                          Karpenter NodePools

observability/            AMP recording + burn-rate rules, SLO definitions,
                          OTel collector (tail sampling + PII redaction),
                          Grafana dashboard

policy/                   Kyverno admission policies, Conftest/OPA for Terraform
ops/                      SQL migrations, Python automation, chaos experiments
.github/workflows/        ci · security · build · terraform · drift ·
                          model-promotion · release
docs/                     architecture, implementation, ADRs, runbooks
```

---

## Project structure in detail

### `infra/terraform/` — 14 modules

| Module | Creates | Purpose |
| --- | --- | --- |
| `vpc` | VPC, 3-tier subnets (public/app/data) × 3 AZ, IGW, per-AZ NAT, route tables, gateway endpoints (s3, dynamodb), interface endpoints (bedrock-runtime, sts, ecr, secretsmanager, kms, logs), flow logs | Network foundation. Data subnets have no NAT route — Aurora is physically unable to reach the internet. |
| `eks` | Cluster IAM role, control-plane security group, EKS cluster (private endpoint, envelope encryption, all 5 log types), OIDC provider, access entries, node IAM role, system-node launch template + managed node group, core addons | The cluster and its tainted `CriticalAddonsOnly` system capacity. |
| `karpenter` | SQS interruption queue, EventBridge spot-interruption/rebalance rules, controller IRSA role, `helm_release` installing Karpenter | Autoscaling for app/batch/GPU capacity (the NodePool objects themselves are GitOps-managed — see `deploy/argocd/platform/10-karpenter-nodepools.yaml`). |
| `ecr` | Repositories per service, image-scanning config, lifecycle policy, repo policy | Where signed images land after `build.yml`. |
| `rds-pgvector` | DB subnet group, security group (ingress only from the EKS cluster SG), parameter groups, Secrets Manager-generated master password, Aurora PostgreSQL Serverless v2 cluster + instances, enhanced-monitoring role | Vector store + relational metadata + `token_ledger`, one Aurora cluster. |
| `s3-datalake` | Versioned/encrypted/public-blocked buckets, **Object Lock** on the audit bucket, TLS-only bucket policy, lifecycle rules, cross-region replication | Document storage, eval datasets, and the immutable audit trail. |
| `kms` | CMK + alias | Instantiated once per data domain (logs / data / secrets / eks). |
| `iam-irsa` | IAM role (trust pinned to `namespace:serviceaccount`), inline policy, managed-policy attachments | Generic module, instantiated once per service in `stacks/platform/workload_identities.tf` — how each pod gets least-privilege AWS access. |
| `alb-waf` | ACM cert, WAFv2 IP block set + prompt-injection regex set, Web ACL, WAF logging | Edge defense: managed rule sets, per-IP/per-key rate limits, prompt-injection screen. |
| `security-baseline` | Account-wide EBS/S3 defaults, IAM password policy, CloudTrail (with S3 data events), GuardDuty (+ EKS runtime monitoring), Security Hub (AFSBP+CIS), Access Analyzer, SNS/EventBridge for high-severity findings | Account-level detection and governance, applied once. |
| `observability` | AMP workspace + rule groups + alertmanager definition, Grafana workspace, SNS alerts, ingest IAM role | Where the burn-rate alert rules and managed Grafana actually live. |
| `bedrock-guardrails` | `aws_bedrock_guardrail` + version, model-invocation logging config + log group | **L1 guardrail** — the Terraform-managed, attestable content-filter/PII/grounding layer. |
| `backup-dr` | Backup vault + Vault Lock, backup IAM role, backup plan + selections, restore-testing plan | DR backbone — the quarterly-drill automation. |

These compose into **`stacks/platform`** (`main.tf`, `workload_identities.tf`, `policies/`), called by `envs/dev` and `envs/prod` with different variables — same code, no drift by construction. `infra/terraform/bootstrap/` is the one-time piece (state backend + GitHub OIDC role), run manually before anything else.

### `services/` — four Python services

- **`ai-gateway`** — the single choke point for every model call: `auth.py` (JWT/JWKS or hashed API key), `ratelimit.py` (Redis token bucket + local semaphore), `prompts.py` (versioned prompt registry, restricted `{{name}}` substitution — not Jinja), `guardrails.py` (L2 pipeline: size caps, secret scanning, injection heuristics, output redaction), `cache.py` (semantic cache, cosine ≥0.97), `router.py` + `providers/` (retry/breaker/failover to Bedrock/vLLM), `cost.py` (token/cost metering into `token_ledger`), `audit.py` (digest write to S3 Object Lock).
- **`rag-service`** — `chunking.py` (structure-aware split/pack/overlap), `embeddings.py`, `store.py` (pgvector HNSW + Postgres FTS, RLS-scoped).
- **`agent-service`** — `agent.py` (bounded step loop with explicit `StopReason`s), `tools.py` (schema-validated, allow-listed, AST-restricted calculator).
- **`eval-service`** — `runner.py` (candidate vs. production eval), `metrics.py` (LLM-judge scoring), `cli.py` (entrypoint used by `model-promotion.yml`).
- **`libs/platform_common`** — shared `telemetry.py` (OTel + redacting structlog processor) and `db.py` (connection pooling), imported by all four services.

### `deploy/` — GitOps

- **`deploy/helm/service/`** — one Helm chart for every service (Deployment, Service, HPA, PDB, default-deny NetworkPolicy, ServiceAccount+IRSA annotation, ExternalSecret, Ingress, PrometheusRule, ServiceMonitor, PreSync migration Job); `deploy/helm/values/{service}.yaml` supplies per-service overrides.
- **`deploy/argocd/`** — `projects/` (AppProjects scoping RBAC/sync windows), `apps/root.yaml` (app-of-apps root) + `platform-addons.yaml`, `platform/` (numbered sync-wave manifests: namespaces → Karpenter NodePools → addons → External Secrets `SecretStore`), `applicationsets/services.yaml` (generates one Application per `{service} × {env}`).

### Deployment flow

```
PR opened
 ├─ ci.yml            lint/type/test, tflint/tfsec/checkov, conftest, helm lint, terraform plan → PR comment
 ├─ security.yml       gitleaks, CodeQL, semgrep, trivy/SCA
 └─ model-promotion.yml (only if a prompt/routing.yaml changed) eval-service runs candidate vs. prod, blocks merge on regression

merge to main
 ├─ build.yml          buildx multi-arch → ECR → trivy → SBOM → cosign sign+attest
 │                      → render_helm_values.py writes the new image digest into the dev values overlay, commits to git
 ├─ terraform.yml      apply envs/dev, then (protected GitHub Environment, manual approval) envs/prod
 │                      → destructive-change guard blocks replacing stateful resources without explicit override
 └─ drift.yml (scheduled) terraform plan against live state, alerts on drift

release.yml (manual)
 → verifies image signature, soaks SLOs in dev, writes the prod values overlay digest, commits

Argo CD (continuously reconciling from git)
 → app-of-apps → ApplicationSet expands {service}×{env} → Application per service
 → PreSync hook runs the Helm migration Job before the Deployment rolls
 → sync waves: namespaces → addons → secrets → services
 → wait_for_argocd.py polls Application health, fails the release job red if it doesn't reach Healthy
```

CI never holds cluster credentials — it only ever writes image digests into `deploy/helm/values/overlays/{env}/` in git; Argo CD is the only thing that talks to the cluster, pulling changes rather than having them pushed. That overlay directory is therefore the audit trail for "what's running where."

---

## The five things this platform does that most do not

**1. You cannot call a model without a guardrail.**
The IAM policy grants `bedrock:InvokeModel` only under
`Condition: bedrock:GuardrailIdentifier`. Bypassing the safety layer fails with
`AccessDenied` rather than succeeding quietly. Two guardrail layers, failing
closed, with a Kyverno policy blocking any production deploy that sets
`GATEWAY_GUARDRAIL_FAIL_MODE` to anything else.

**2. Every request is attributed to a tenant, a prompt version and a cost.**
`token_ledger` records tenant, tier, route, model, **prompt version**, tokens,
cost, cache hit and latency for every call. AWS billing knows what Bedrock cost
the account; it has no idea which tenant, feature or prompt caused it — and
that is the only question anyone ever asks.

**3. A prompt change is a measured change.**
Prompts are versioned artefacts with owners, changelogs, eval datasets and
promotion thresholds. Changing one triggers `model-promotion.yml`, which runs
the candidate and the current production version against a golden set and
comments the metric *and cost* deltas on the PR. A regression blocks the merge.

**4. Cost is an alert, not a monthly report.**
`TokenSpendSuddenJump` pages at 5× the six-hour baseline. A monthly budget
alert finds a 3am runaway loop after ~USD 900; this finds it after ~USD 12.
A weekly job reconciles the gateway's price book against Cost Explorer and
fails on >5% drift.

**5. The agent cannot reach the internet.**
Bounded steps, bounded cost, bounded wall clock, loop detection, a registered
tool allow-list with JSON-schema validation and scope requirements — and a
NetworkPolicy with zero external egress. A prompt-injected agent has nowhere to
send what it retrieved.

---

## Quick start

```bash
make bootstrap ENV=dev          # state backend + OIDC roles (once per account)
make infra ENV=dev              # terraform apply
make gitops ENV=dev             # Argo CD + root application
make seed ENV=dev               # dev tenants and keys
make smoke ENV=dev              # end-to-end verification
```

Full walkthrough, including the manual Bedrock model-access step that must
happen first: [`docs/implementation.md`](docs/implementation.md).

---

## Local development

```bash
make dev-up                     # postgres+pgvector and redis in docker compose
make test                       # 58 unit tests across four services
make lint                       # ruff, mypy, terraform fmt, tflint, helm lint
make security                   # trivy, checkov, tfsec, gitleaks, semgrep
```

The test suite is deliberately weighted towards the behaviours that cost money
or leak capability rather than towards coverage: retry/breaker/failover
semantics (including the cases where failover must **not** happen), guardrail
false positives as well as true positives, agent budget and loop termination,
tool schema rejection, prompt template injection, and the eval gate's refusal
to reward a hallucination over a correct refusal.

---

## Job-requirement mapping

| Requirement | Where it lives |
| --- | --- |
| AWS | `infra/terraform/modules/` — VPC, EKS, ECR, S3, RDS, IAM, KMS, ALB, WAF, CloudWatch, Backup, GuardDuty |
| Terraform | 14 modules, one composed stack, two environments, remote state, OIDC, drift detection |
| Kubernetes | EKS 1.31, Karpenter, PSA `restricted`, NetworkPolicies, PDBs, topology spread, HPA on custom metrics, KEDA |
| Docker | Distroless, non-root, read-only rootfs, multi-arch, signed, SBOM-attested |
| GitHub Actions | 7 workflows: CI, security, build, terraform, drift, model promotion, release |
| Argo CD | App-of-apps, AppProjects with RBAC and sync windows, ApplicationSet, sync waves, PreSync migrations |
| Python | 4 services + 6 automation tools, async throughout, typed, tested |
| SRE | SLIs as good/total ratios, multi-window burn-rate alerts, error budget policy, 10 runbooks, chaos experiments |
| DevSecOps | Trivy, Checkov, tfsec, Semgrep, gitleaks, CodeQL, Bandit, cosign, Kyverno, permissions boundaries, IRSA |
| MLOps | MLflow tracking, model registry table, eval datasets in S3, re-index as a migration |
| LLMOps | Model gateway, prompt registry with versions and owners, eval-gated promotion, semantic cache, token metering |
| Agentic AI | Bounded multi-step agent, schema-validated tools, loop detection, full run traces persisted and replayable |
| RAG | Structure-aware chunking, hybrid retrieval with RRF, RLS tenant isolation, zero-downtime re-index |
| Observability | AMP + Managed Grafana + OTel with tail sampling and PII redaction, 19-panel dashboard |
| Guardrails | Bedrock Guardrails (L1) + application pipeline (L2), fail-closed, IAM-enforced |
| Governance | Immutable audit trail with Object Lock, prompt/model version tracking, CloudTrail data events |
| HA | 3 AZ everywhere, Aurora multi-AZ, PDBs, hard zone topology spread, NAT per AZ |
| DR | Cross-region replication with RTC, AWS Backup with Vault Lock, quarterly drills with measured RTO |
| Cost optimisation | Per-tenant ledger, spot + Graviton + consolidation, semantic cache, budgets, anomaly detection, break-even analysis |
| Automation | Cost reconciliation, SLO checks, DR driver, re-indexing, GitOps value rendering, rollout observation |

---

## Honest limitations

- **No production answer-quality SLO.** Quality is measured offline at
  promotion time. Online LLM-judge sampling is scoped, not built. See the
  "Known gaps" section of [`docs/slo.md`](docs/slo.md).
- **No per-tenant SLO.** All SLIs are fleet-wide, for cardinality reasons. The
  ledger has the data when a contractual per-tenant SLA appears.
- **Warm standby, not active-active.** A 60-minute RTO does not justify
  doubling fixed cost — and a drilled warm standby beats an untested hot one.
- **Account IDs and domains are placeholders.** Replace `111122223333`,
  `your-org` and `ai.example.com` before applying (there is a one-liner in the
  implementation guide).

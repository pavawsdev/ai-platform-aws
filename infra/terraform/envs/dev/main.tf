module "platform" {
  source = "../../stacks/platform"

  project            = var.project
  environment        = "dev"
  region             = var.region
  owner              = var.owner
  cost_center        = var.cost_center
  repo_url           = var.repo_url
  extra_tags         = var.extra_tags
  workload_namespace = var.workload_namespace

  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway

  kubernetes_version      = var.kubernetes_version
  eks_public_access       = var.eks_public_access
  eks_public_access_cidrs = var.eks_public_access_cidrs
  system_node_count       = var.system_node_count
  cluster_access_entries  = var.cluster_access_entries

  rds_min_acu        = var.rds_min_acu
  rds_max_acu        = var.rds_max_acu
  rds_instance_count = var.rds_instance_count

  allowed_bedrock_models   = var.allowed_bedrock_models
  allowed_embedding_models = var.allowed_embedding_models

  domain_name                = var.domain_name
  waf_rate_limit             = var.waf_rate_limit
  waf_rate_limit_per_key     = var.waf_rate_limit_per_key
  waf_block_prompt_injection = var.waf_block_prompt_injection

  manage_account_security = var.manage_account_security
  manage_bedrock_logging  = var.manage_bedrock_logging

  create_grafana     = var.create_grafana
  alert_emails       = var.alert_emails
  monthly_budget_usd = var.monthly_budget_usd
  bedrock_budget_usd = var.bedrock_budget_usd

  enable_dr      = var.enable_dr
  dr_kms_key_arn = var.dr_kms_key_arn
  dr_vault_arn   = var.dr_vault_arn

  ci_role_arn = var.ci_role_arn
}

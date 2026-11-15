###############################################################################
# The platform stack: one composition, instantiated per environment from
# envs/<env>. Everything environment-specific arrives as a variable, so dev and
# prod run identical code and differ only in tfvars. That is what makes a dev
# rehearsal of a change meaningful.
###############################################################################
locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-${var.environment}"

  tags = merge(var.extra_tags, {
    Project     = var.project
    Platform    = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
    CostCenter  = var.cost_center
    Repo        = var.repo_url
  })

  services = ["ai-gateway", "agent-service", "rag-service", "eval-service", "doc-ingestor"]
}

module "kms" {
  source = "../../modules/kms"

  name                    = local.name
  region                  = var.region
  multi_region            = var.enable_dr
  deletion_window_in_days = var.environment == "prod" ? 30 : 7
  tags                    = local.tags
}

module "vpc" {
  source = "../../modules/vpc"

  name               = local.name
  cluster_name       = local.cluster_name
  region             = var.region
  cidr_block         = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  kms_key_arn        = module.kms.key_arns["logs"]
  tags               = local.tags
}

module "s3" {
  source = "../../modules/s3-datalake"

  name                 = local.name
  kms_key_arn          = module.kms.key_arns["data"]
  enable_replication   = var.enable_dr
  dr_bucket_arn_prefix = var.enable_dr ? "arn:aws:s3:::${var.project}-dr" : ""
  dr_kms_key_arn       = var.dr_kms_key_arn
  force_destroy        = var.environment != "prod"
  tags                 = local.tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name           = local.cluster_name
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.app_subnet_ids
  endpoint_public_access = var.eks_public_access
  public_access_cidrs    = var.eks_public_access_cidrs

  eks_kms_key_arn  = module.kms.key_arns["eks"]
  logs_kms_key_arn = module.kms.key_arns["logs"]
  data_kms_key_arn = module.kms.key_arns["data"]

  system_desired_size = var.system_node_count
  system_min_size     = var.system_node_count
  system_max_size     = var.system_node_count * 2

  access_entries = var.cluster_access_entries

  tags = local.tags
}

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn
  tags              = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  namespace                = var.project
  repositories             = local.services
  kms_key_arn              = module.kms.key_arns["data"]
  pull_principal_arns      = [module.eks.node_role_arn]
  push_principal_arns      = var.ci_role_arn == "" ? [] : [var.ci_role_arn]
  manage_registry_scanning = var.environment == "prod"
  force_delete             = var.environment != "prod"
  tags                     = local.tags
}

module "rds" {
  source = "../../modules/rds-pgvector"

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.data_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  kms_key_arn                = module.kms.key_arns["data"]
  secrets_kms_key_arn        = module.kms.key_arns["secrets"]

  min_acu               = var.rds_min_acu
  max_acu               = var.rds_max_acu
  instance_count        = var.rds_instance_count
  backup_retention_days = var.environment == "prod" ? 35 : 7
  deletion_protection   = var.environment == "prod"
  skip_final_snapshot   = var.environment != "prod"

  tags = merge(local.tags, { Backup = "true" })
}

module "edge" {
  source = "../../modules/alb-waf"

  name                      = local.name
  kms_key_arn               = module.kms.key_arns["logs"]
  create_certificate        = var.domain_name != ""
  domain_name               = var.domain_name
  subject_alternative_names = var.domain_name == "" ? [] : ["*.${var.domain_name}"]
  rate_limit_per_5min       = var.waf_rate_limit
  rate_limit_per_key_5min   = var.waf_rate_limit_per_key
  prompt_injection_block    = var.waf_block_prompt_injection
  tags                      = local.tags
}

module "guardrails" {
  source = "../../modules/bedrock-guardrails"

  name                      = local.name
  kms_key_arn               = module.kms.key_arns["data"]
  logs_kms_key_arn          = module.kms.key_arns["logs"]
  audit_bucket_name         = module.s3.bucket_names["audit"]
  manage_invocation_logging = var.manage_bedrock_logging
  tags                      = local.tags
}

module "security" {
  source = "../../modules/security-baseline"

  name             = local.name
  logs_kms_key_arn = module.kms.key_arns["logs"]
  data_kms_key_arn = module.kms.key_arns["data"]
  log_bucket_name  = module.s3.bucket_names["logs"]

  audited_s3_arn_prefixes = [
    "${module.s3.bucket_arns["documents"]}/",
    "${module.s3.bucket_arns["model-artifacts"]}/",
  ]

  manage_cloudtrail      = var.manage_account_security
  manage_guardduty       = var.manage_account_security
  manage_securityhub     = var.manage_account_security
  manage_access_analyzer = var.manage_account_security
  manage_password_policy = var.manage_account_security

  tags = local.tags
}

module "observability" {
  source = "../../modules/observability"

  name              = local.name
  cluster_name      = module.eks.cluster_name
  kms_key_arn       = module.kms.key_arns["logs"]
  logs_kms_key_arn  = module.kms.key_arns["logs"]
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  create_grafana = var.create_grafana
  alert_emails   = var.alert_emails
  rds_cluster_id = split(":", module.rds.cluster_arn)[6]

  monthly_budget_usd = var.monthly_budget_usd
  bedrock_budget_usd = var.bedrock_budget_usd

  rule_groups = {
    for f in fileset("${path.module}/../../../../observability/prometheus", "*.rules.yaml") :
    replace(f, ".rules.yaml", "") => file("${path.module}/../../../../observability/prometheus/${f}")
  }

  tags = local.tags
}

module "backup" {
  source = "../../modules/backup-dr"

  name          = local.name
  kms_key_arn   = module.kms.key_arns["data"]
  sns_topic_arn = module.observability.alert_topic_arns["critical"]
  resource_arns = [module.rds.cluster_arn]

  enable_vault_lock          = var.environment == "prod"
  enable_restore_testing     = var.environment == "prod"
  restore_test_resource_arns = [module.rds.cluster_arn]
  dr_vault_arn               = var.dr_vault_arn

  tags = local.tags
}

###############################################################################
# prod: multi-AZ everywhere, private API server, WAF in block mode, DR on.
###############################################################################
project     = "aiplat"
region      = "ap-south-1"
owner       = "platform-engineering"
cost_center = "CC-4821-AI"
repo_url    = "https://github.com/your-org/ai-platform-aws"

vpc_cidr           = "10.50.0.0/16"
az_count           = 3
single_nat_gateway = false

kubernetes_version      = "1.31"
eks_public_access       = false
eks_public_access_cidrs = []
system_node_count       = 3

rds_min_acu        = 2
rds_max_acu        = 64
rds_instance_count = 2

domain_name                = "ai.example.com"
waf_rate_limit             = 2000
waf_rate_limit_per_key     = 600
waf_block_prompt_injection = true

manage_account_security = true
manage_bedrock_logging  = true

create_grafana = true
alert_emails = {
  critical = ["platform-oncall@example.com", "ai-platform-pager@example.com"]
  warning  = ["platform-alerts@example.com"]
}
monthly_budget_usd = "9000"
bedrock_budget_usd = "4000"

enable_dr      = true
dr_kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:key/REPLACE-ME"
dr_vault_arn   = "arn:aws:backup:ap-southeast-1:111122223333:backup-vault:aiplat-prod-dr-vault"

cluster_access_entries = {
  platform_admins = {
    principal_arn = "arn:aws:iam::111122223333:role/PlatformAdmin"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope = { type = "cluster" }
    }]
  }
  # Developers get read-only in prod. Changes go through Argo CD, not kubectl.
  developers = {
    principal_arn = "arn:aws:iam::111122223333:role/Developer"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
      access_scope = { type = "namespace", namespaces = ["ai-platform"] }
    }]
  }
  # Break-glass: assumed only through an approved, time-boxed, alarmed path.
  break_glass = {
    principal_arn = "arn:aws:iam::111122223333:role/BreakGlassSRE"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope = { type = "cluster" }
    }]
  }
  gitops = {
    principal_arn = "arn:aws:iam::111122223333:role/aiplat-argocd"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope = { type = "cluster" }
    }]
  }
}

ci_role_arn = "arn:aws:iam::111122223333:role/aiplat-github-actions"

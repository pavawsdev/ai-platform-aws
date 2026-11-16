###############################################################################
# dev: identical code path to prod, deliberately cheaper.
# Monthly cost of an idle dev stack with these settings is roughly USD 210
# (1 NAT ~32, 3x m6i.large system nodes ~105, Aurora 2x0.5 ACU ~45, AMP/AMG ~15,
#  misc ~15) plus Bedrock usage. See docs/cost.md for the model.
###############################################################################
project     = "aiplat"
region      = "ap-south-1"
owner       = "platform-engineering"
cost_center = "CC-4821-AI"
repo_url    = "https://github.com/your-org/ai-platform-aws"

vpc_cidr           = "10.40.0.0/16"
az_count           = 3
single_nat_gateway = true

kubernetes_version = "1.31"
eks_public_access  = true
# Replace with your office / VPN egress. 0.0.0.0/0 is rejected by a validation.
eks_public_access_cidrs = ["203.0.113.10/32"]
system_node_count       = 2

rds_min_acu        = 0.5
rds_max_acu        = 4
rds_instance_count = 1

domain_name                = ""
waf_rate_limit             = 5000
waf_rate_limit_per_key     = 2000
waf_block_prompt_injection = false

# The security baseline is account-scoped; prod owns it. Dev only consumes.
manage_account_security = false
manage_bedrock_logging  = false

create_grafana = false
alert_emails = {
  critical = ["platform-oncall@example.com"]
  warning  = ["platform-oncall@example.com"]
}
monthly_budget_usd = "400"
bedrock_budget_usd = "150"

enable_dr = false

cluster_access_entries = {
  platform_admins = {
    principal_arn = "arn:aws:iam::111122223333:role/PlatformAdmin"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope = { type = "cluster" }
    }]
  }
  developers = {
    principal_arn = "arn:aws:iam::111122223333:role/Developer"
    policy_associations = [{
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
      access_scope = { type = "namespace", namespaces = ["ai-platform"] }
    }]
  }
}

ci_role_arn = "arn:aws:iam::111122223333:role/aiplat-github-actions"

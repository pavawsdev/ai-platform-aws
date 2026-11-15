variable "project" {
  type    = string
  default = "aiplat"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" { type = string }
variable "owner" { type = string }
variable "cost_center" { type = string }
variable "repo_url" { type = string }

variable "extra_tags" {
  type    = map(string)
  default = {}
}

# ---------------- network ----------------
variable "vpc_cidr" { type = string }
variable "az_count" {
  type    = number
  default = 3
}
variable "single_nat_gateway" {
  type    = bool
  default = false
}

# ---------------- cluster ----------------
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
variable "eks_public_access" {
  type    = bool
  default = false
}
variable "eks_public_access_cidrs" {
  type    = list(string)
  default = []
}
variable "system_node_count" {
  type    = number
  default = 3
}
variable "cluster_access_entries" {
  type    = any
  default = {}
}
variable "workload_namespace" {
  type    = string
  default = "ai-platform"
}

# ---------------- data ----------------
variable "rds_min_acu" {
  type    = number
  default = 0.5
}
variable "rds_max_acu" {
  type    = number
  default = 16
}
variable "rds_instance_count" {
  type    = number
  default = 2
}

# ---------------- models ----------------
variable "allowed_bedrock_models" {
  description = "Explicit model allow-list. Adding a model is a reviewed change, not a config flag."
  type        = list(string)
  default = [
    "anthropic.claude-3-5-sonnet-20241022-v2:0",
    "anthropic.claude-3-5-haiku-20241022-v1:0",
    "meta.llama3-1-70b-instruct-v1:0",
  ]
}

variable "allowed_embedding_models" {
  type    = list(string)
  default = ["amazon.titan-embed-text-v2:0", "cohere.embed-english-v3"]
}

# ---------------- edge ----------------
variable "domain_name" {
  type    = string
  default = ""
}
variable "waf_rate_limit" {
  type    = number
  default = 2000
}
variable "waf_rate_limit_per_key" {
  type    = number
  default = 600
}
variable "waf_block_prompt_injection" {
  type    = bool
  default = false
}

# ---------------- account singletons ----------------
variable "manage_account_security" {
  type    = bool
  default = true
}
variable "manage_bedrock_logging" {
  type    = bool
  default = true
}

# ---------------- observability / finops ----------------
variable "create_grafana" {
  type    = bool
  default = true
}
variable "alert_emails" {
  type = map(list(string))
  default = {
    critical = []
    warning  = []
  }
}
variable "monthly_budget_usd" {
  type    = string
  default = "3000"
}
variable "bedrock_budget_usd" {
  type    = string
  default = "1200"
}

# ---------------- DR ----------------
variable "enable_dr" {
  type    = bool
  default = false
}
variable "dr_kms_key_arn" {
  type    = string
  default = ""
}
variable "dr_vault_arn" {
  type    = string
  default = ""
}

# ---------------- CI ----------------
variable "ci_role_arn" {
  type    = string
  default = ""
}

variable "name" { type = string }
variable "kms_key_arn" { type = string }

variable "create_certificate" {
  type    = bool
  default = true
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "subject_alternative_names" {
  type    = list(string)
  default = []
}

variable "blocked_cidrs" {
  type    = list(string)
  default = []
}

variable "managed_rule_groups" {
  type = list(object({
    name       = string
    count_only = bool
  }))
  default = [
    { name = "AWSManagedRulesCommonRuleSet", count_only = false },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", count_only = false },
    { name = "AWSManagedRulesAmazonIpReputationList", count_only = false },
    { name = "AWSManagedRulesAnonymousIpList", count_only = true },
    { name = "AWSManagedRulesSQLiRuleSet", count_only = false },
  ]
}

variable "rate_limit_per_5min" {
  type    = number
  default = 2000
}

variable "rate_limit_per_key_5min" {
  type    = number
  default = 600
}

variable "prompt_injection_block" {
  description = "Start in COUNT mode, promote to BLOCK once false-positive rate is measured."
  type        = bool
  default     = false
}

variable "prompt_injection_patterns" {
  type = list(string)
  default = [
    "ignore (all )?(previous|prior|above) instructions",
    "disregard (the )?(system|developer) (prompt|message)",
    "you are now (in )?(dan|developer mode|jailbreak)",
    "reveal (your )?(system prompt|instructions|initial prompt)",
    "print (the )?(contents of )?(your )?(system|hidden) (prompt|message)",
    "(base64|rot13)\\s*(decode|encoded)\\s*(and )?(then )?(execute|run)",
  ]
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "tags" { type = map(string) }

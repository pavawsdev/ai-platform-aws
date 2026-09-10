variable "project" {
  type    = string
  default = "aiplat"
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

variable "github_oidc_provider_arn" {
  type    = string
  default = ""
}

variable "github_subject_claims" {
  type    = list(string)
  default = ["repo:your-org/ai-platform-aws:*"]
}

variable "github_apply_subject_claims" {
  type = list(string)
  default = [
    "repo:your-org/ai-platform-aws:environment:dev",
    "repo:your-org/ai-platform-aws:environment:prod",
  ]
}

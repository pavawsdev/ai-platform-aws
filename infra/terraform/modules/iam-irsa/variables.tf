variable "role_name" { type = string }
variable "namespace" { type = string }
variable "service_account" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "policy_json" {
  type    = string
  default = null
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

variable "max_session_duration" {
  type    = number
  default = 3600
}

variable "tags" { type = map(string) }

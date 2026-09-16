variable "namespace" { type = string }
variable "repositories" { type = list(string) }
variable "kms_key_arn" { type = string }
variable "pull_principal_arns" { type = list(string) }

variable "push_principal_arns" {
  type    = list(string)
  default = []
}

variable "manage_registry_scanning" {
  description = "Registry scanning config is account-wide; only one env should own it."
  type        = bool
  default     = false
}

variable "force_delete" {
  type    = bool
  default = false
}

variable "tags" { type = map(string) }

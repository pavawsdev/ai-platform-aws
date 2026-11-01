variable "name" { type = string }
variable "kms_key_arn" { type = string }
variable "sns_topic_arn" { type = string }

variable "resource_arns" {
  type    = list(string)
  default = []
}

variable "dr_vault_arn" {
  description = "Backup vault ARN in the DR region; empty disables cross-region copy."
  type        = string
  default     = ""
}

variable "daily_retention_days" {
  type    = number
  default = 35
}
variable "weekly_retention_days" {
  type    = number
  default = 180
}
variable "monthly_retention_days" {
  type    = number
  default = 2555
}

variable "enable_vault_lock" {
  type    = bool
  default = true
}
variable "vault_lock_changeable_for_days" {
  type    = number
  default = 3
}
variable "min_retention_days" {
  type    = number
  default = 7
}
variable "max_retention_days" {
  type    = number
  default = 2555
}

variable "enable_restore_testing" {
  type    = bool
  default = true
}
variable "restore_test_resource_arns" {
  type    = list(string)
  default = []
}

variable "tags" { type = map(string) }

variable "name" { type = string }
variable "logs_kms_key_arn" { type = string }
variable "data_kms_key_arn" { type = string }
variable "log_bucket_name" { type = string }

variable "audited_s3_arn_prefixes" {
  description = "S3 object ARN prefixes whose data events are recorded for governance."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 365
}

# These are account-scoped singletons: only one environment (usually prod, or a
# dedicated security account) should manage them.
variable "manage_cloudtrail" {
  type    = bool
  default = true
}
variable "manage_guardduty" {
  type    = bool
  default = true
}
variable "manage_securityhub" {
  type    = bool
  default = true
}
variable "manage_access_analyzer" {
  type    = bool
  default = true
}
variable "manage_password_policy" {
  type    = bool
  default = true
}

variable "tags" { type = map(string) }

variable "name" { type = string }
variable "kms_key_arn" { type = string }

variable "audit_retention_days" {
  description = "WORM retention on the governance/audit bucket."
  type        = number
  default     = 2555 # 7 years
}

variable "noncurrent_expiration_days" {
  type    = number
  default = 365
}

variable "enable_replication" {
  type    = bool
  default = false
}

variable "dr_bucket_arn_prefix" {
  description = "e.g. arn:aws:s3:::aiplat-dr"
  type        = string
  default     = ""
}

variable "dr_kms_key_arn" {
  type    = string
  default = ""
}

variable "force_destroy" {
  type    = bool
  default = false
}

variable "tags" { type = map(string) }

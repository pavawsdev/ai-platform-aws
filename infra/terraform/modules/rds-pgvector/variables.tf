variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "allowed_security_group_ids" { type = list(string) }
variable "kms_key_arn" { type = string }
variable "secrets_kms_key_arn" { type = string }

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "parameter_group_family" {
  type    = string
  default = "aurora-postgresql16"
}

variable "database_name" {
  type    = string
  default = "aiplatform"
}

variable "master_username" {
  type    = string
  default = "aiplatform_admin"
}

variable "min_acu" {
  type    = number
  default = 0.5
}

variable "max_acu" {
  type    = number
  default = 16
}

variable "instance_count" {
  description = "1 writer + N readers. Prod uses 2 for multi-AZ failover."
  type        = number
  default     = 2
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "secret_recovery_window_days" {
  type    = number
  default = 7
}

variable "tags" { type = map(string) }

variable "name" { type = string }
variable "region" { type = string }

variable "deletion_window_in_days" {
  type    = number
  default = 30
}

variable "multi_region" {
  description = "Multi-region keys are required for cross-region DR replication of encrypted S3 objects and RDS snapshots."
  type        = bool
  default     = true
}

variable "tags" { type = map(string) }

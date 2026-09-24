variable "name" { type = string }
variable "cluster_name" { type = string }
variable "region" { type = string }

variable "cidr_block" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 (multi-AZ HA requirement)."
  }
}

variable "single_nat_gateway" {
  description = "true in dev to save ~USD 65/AZ/month. Never true in prod."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  type = list(string)
  default = [
    "ecr.api", "ecr.dkr", "sts", "logs", "monitoring",
    "secretsmanager", "kms", "ssm", "ssmmessages", "ec2messages",
    "bedrock-runtime", "bedrock-agent-runtime", "sagemaker.runtime",
    "elasticloadbalancing", "autoscaling", "sqs", "xray"
  ]
}

variable "flow_log_retention_days" {
  type    = number
  default = 365
}

variable "kms_key_arn" { type = string }
variable "tags" { type = map(string) }

variable "cluster_name" { type = string }
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "endpoint_public_access" {
  type    = bool
  default = false
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the EKS API server to 0.0.0.0/0."
  }
}

variable "service_ipv4_cidr" {
  type    = string
  default = "172.20.0.0/16"
}

variable "eks_kms_key_arn" { type = string }
variable "logs_kms_key_arn" { type = string }
variable "data_kms_key_arn" { type = string }

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "system_instance_types" {
  type    = list(string)
  default = ["m6i.large", "m6a.large", "m5.large"]
}

variable "system_desired_size" {
  type    = number
  default = 3
}
variable "system_min_size" {
  type    = number
  default = 3
}
variable "system_max_size" {
  type    = number
  default = 6
}

variable "access_entries" {
  description = "IAM principals granted cluster access, with scoped access policies."
  type        = any
  default     = {}
}

variable "addons" {
  type = any
  default = {
    vpc-cni                = {}
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
  }
}

variable "tags" { type = map(string) }

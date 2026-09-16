variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }
variable "node_role_arn" { type = string }

variable "namespace" {
  type    = string
  default = "kube-system"
}

variable "chart_version" {
  type    = string
  default = "1.0.6"
}

variable "install_via_helm" {
  description = "Karpenter is a bootstrap dependency, so it is installed by Terraform rather than Argo CD (chicken-and-egg: Argo CD needs nodes)."
  type        = bool
  default     = true
}

variable "tags" { type = map(string) }

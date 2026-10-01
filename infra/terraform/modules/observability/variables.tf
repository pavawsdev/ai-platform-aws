variable "name" { type = string }
variable "cluster_name" { type = string }
variable "kms_key_arn" { type = string }
variable "logs_kms_key_arn" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "create_grafana" {
  type    = bool
  default = true
}

variable "grafana_version" {
  type    = string
  default = "10.4"
}

variable "grafana_auth_provider" {
  type    = string
  default = "AWS_SSO"
}

variable "alert_emails" {
  type = map(list(string))
  default = {
    critical = []
    warning  = []
  }
}

variable "alertmanager_definition" {
  type    = string
  default = <<-YAML
    alertmanager_config: |
      route:
        receiver: default
        group_by: [alertname, service, severity]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        routes:
          - matchers: [severity = critical]
            receiver: critical
            repeat_interval: 1h
      receivers:
        - name: default
        - name: critical
  YAML
}

variable "rule_groups" {
  description = "map of namespace name -> rule group YAML (loaded from observability/prometheus/*)"
  type        = map(string)
  default     = {}
}

variable "rds_cluster_id" {
  type    = string
  default = ""
}

variable "rds_connection_threshold" {
  type    = number
  default = 400
}

variable "bedrock_p99_latency_ms" {
  type    = number
  default = 8000
}

variable "monthly_budget_usd" {
  type    = string
  default = "3000"
}

variable "bedrock_budget_usd" {
  type    = string
  default = "1200"
}

variable "anomaly_threshold_usd" {
  type    = number
  default = 50
}

variable "tags" { type = map(string) }

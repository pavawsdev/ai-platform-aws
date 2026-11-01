###############################################################################
# Observability backbone.
#  - Amazon Managed Prometheus (AMP) as the durable, HA metric store. The
#    in-cluster Prometheus only scrapes and remote-writes; losing the cluster
#    does not lose the telemetry that explains why we lost the cluster.
#  - Amazon Managed Grafana for dashboards with SSO + audit.
#  - Alertmanager definition and recording/alerting rules are managed as AMP
#    rule groups so alerting survives a cluster rebuild.
#  - CloudWatch alarms for the AWS-managed dependencies (Aurora, ALB, Bedrock).
###############################################################################
locals { tags = merge(var.tags, { Module = "observability" }) }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_prometheus_workspace" "this" {
  alias       = var.name
  kms_key_arn = var.kms_key_arn
  tags        = local.tags

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/${var.name}"
  retention_in_days = 365
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_prometheus_alert_manager_definition" "this" {
  workspace_id = aws_prometheus_workspace.this.id
  definition   = var.alertmanager_definition
}

resource "aws_prometheus_rule_group_namespace" "this" {
  for_each = var.rule_groups

  name         = each.key
  workspace_id = aws_prometheus_workspace.this.id
  data         = each.value
}

###############################  Grafana  #####################################
resource "aws_iam_role" "grafana" {
  count = var.create_grafana ? 1 : 0
  name  = "${var.name}-grafana"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "grafana" {
  count = var.create_grafana ? 1 : 0
  role  = aws_iam_role.grafana[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:ListWorkspaces", "aps:DescribeWorkspace", "aps:QueryMetrics",
          "aps:GetLabels", "aps:GetSeries", "aps:GetMetricMetadata"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics",
          "logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery",
          "logs:StopQuery", "logs:GetQueryResults", "logs:GetLogEvents",
          "xray:GetTraceSummaries", "xray:BatchGetTraces", "xray:GetTraceGraph",
          "tag:GetResources"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_grafana_workspace" "this" {
  count = var.create_grafana ? 1 : 0

  name                      = var.name
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = [var.grafana_auth_provider]
  permission_type           = "SERVICE_MANAGED"
  role_arn                  = aws_iam_role.grafana[0].arn
  data_sources              = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  notification_destinations = ["SNS"]
  grafana_version           = var.grafana_version
  tags                      = local.tags

  configuration = jsonencode({
    plugins         = { pluginAdminEnabled = false }
    unifiedAlerting = { enabled = true }
  })
}

##############################  Alert routing  ################################
resource "aws_sns_topic" "alerts" {
  for_each = toset(["critical", "warning"])

  name              = "${var.name}-alerts-${each.key}"
  kms_master_key_id = var.logs_kms_key_arn
  tags              = merge(local.tags, { Severity = each.key })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = {
    for pair in flatten([
      for sev, addrs in var.alert_emails : [
        for a in addrs : { key = "${sev}-${a}", sev = sev, addr = a }
      ]
    ]) : pair.key => pair
  }

  topic_arn = aws_sns_topic.alerts[each.value.sev].arn
  protocol  = "email"
  endpoint  = each.value.addr
}

###########################  Ingest IAM (IRSA)  ###############################
data "aws_iam_policy_document" "ingest_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringLike"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:observability:*"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.name}-amp-ingest"
  assume_role_policy = data.aws_iam_policy_document.ingest_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "ingest" {
  role = aws_iam_role.ingest.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata", "aps:QueryMetrics"]
        Resource = aws_prometheus_workspace.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:CreateLogGroup", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/*"
      }
    ]
  })
}

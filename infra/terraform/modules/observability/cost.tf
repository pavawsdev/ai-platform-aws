###############################################################################
# FinOps controls.
#  - A hard monthly budget with forecast + actual alerts.
#  - A dedicated budget for Bedrock (token spend is the volatile line item).
#  - Cost anomaly detection with an ML monitor, wired to the same SNS topics.
# Per-tenant token spend is tracked in the application (see ai-gateway
# cost.py + the token_ledger table) because AWS billing has no notion of
# our tenants.
###############################################################################
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Platform$%s", var.name)]
  }

  dynamic "notification" {
    for_each = [
      { threshold = 60, type = "ACTUAL", sev = "warning" },
      { threshold = 85, type = "ACTUAL", sev = "critical" },
      { threshold = 100, type = "FORECASTED", sev = "critical" },
    ]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.type
      subscriber_sns_topic_arns = [aws_sns_topic.alerts[notification.value.sev].arn]
    }
  }
}

resource "aws_budgets_budget" "bedrock" {
  name         = "${var.name}-bedrock-tokens"
  budget_type  = "COST"
  limit_amount = var.bedrock_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts["critical"].arn]
  }
}

resource "aws_ce_anomaly_monitor" "service" {
  name              = "${var.name}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = local.tags
}

resource "aws_ce_anomaly_subscription" "this" {
  name             = "${var.name}-anomalies"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.service.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts["warning"].arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = local.tags
}

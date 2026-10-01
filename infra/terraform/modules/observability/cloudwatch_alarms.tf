###############################################################################
# CloudWatch alarms for AWS-managed dependencies. Kubernetes-native SLO alerts
# live in observability/prometheus/*.yaml and are loaded into AMP as rule
# groups; these cover what Prometheus cannot see.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.rds_cluster_id == "" ? 0 : 1

  alarm_name          = "${var.name}-aurora-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora CPU above 80% - vector search may be degrading p99 latency"
  dimensions          = { DBClusterIdentifier = var.rds_cluster_id }
  alarm_actions       = [aws_sns_topic.alerts["warning"].arn]
  ok_actions          = [aws_sns_topic.alerts["warning"].arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count = var.rds_cluster_id == "" ? 0 : 1

  alarm_name          = "${var.name}-aurora-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.rds_connection_threshold
  alarm_description   = "Connection pool exhaustion risk - check rag-service pool sizing"
  dimensions          = { DBClusterIdentifier = var.rds_cluster_id }
  alarm_actions       = [aws_sns_topic.alerts["critical"].arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "bedrock_throttle" {
  alarm_name          = "${var.name}-bedrock-throttling"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "InvocationThrottles"
  namespace           = "AWS/Bedrock"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "Bedrock is throttling us - gateway should be shedding to the fallback model; verify circuit breaker"
  alarm_actions       = [aws_sns_topic.alerts["critical"].arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "bedrock_latency" {
  alarm_name          = "${var.name}-bedrock-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "InvocationLatency"
  namespace           = "AWS/Bedrock"
  period              = 300
  extended_statistic  = "p99"
  threshold           = var.bedrock_p99_latency_ms
  treat_missing_data  = "notBreaching"
  alarm_description   = "Upstream model p99 latency breaching the budget that feeds our end-to-end SLO"
  alarm_actions       = [aws_sns_topic.alerts["warning"].arn]
  tags                = local.tags
}

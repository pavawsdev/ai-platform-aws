output "amp_workspace_id" { value = aws_prometheus_workspace.this.id }
output "amp_remote_write_url" { value = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write" }
output "amp_query_url" { value = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/query" }
output "grafana_endpoint" { value = try(aws_grafana_workspace.this[0].endpoint, "") }
output "ingest_role_arn" { value = aws_iam_role.ingest.arn }
output "alert_topic_arns" { value = { for k, v in aws_sns_topic.alerts : k => v.arn } }

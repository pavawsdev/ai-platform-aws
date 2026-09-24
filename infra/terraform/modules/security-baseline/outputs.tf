output "security_topic_arn" { value = aws_sns_topic.security.arn }
output "guardduty_detector_id" { value = try(aws_guardduty_detector.this[0].id, "") }

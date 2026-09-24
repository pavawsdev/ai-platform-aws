output "web_acl_arn" { value = aws_wafv2_web_acl.this.arn }
output "certificate_arn" { value = try(aws_acm_certificate.this[0].arn, "") }
output "certificate_validation_records" {
  value = try({
    for dvo in aws_acm_certificate.this[0].domain_validation_options :
    dvo.domain_name => { name = dvo.resource_record_name, type = dvo.resource_record_type, value = dvo.resource_record_value }
  }, {})
}

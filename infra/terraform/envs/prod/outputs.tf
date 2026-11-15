output "platform" {
  value     = module.platform
  sensitive = true
}

output "cluster_name" { value = module.platform.cluster_name }
output "cluster_endpoint" { value = module.platform.cluster_endpoint }
output "ecr_repositories" { value = module.platform.ecr_repositories }
output "workload_role_arns" { value = module.platform.workload_role_arns }
output "observability" { value = module.platform.observability }
output "guardrail" { value = module.platform.guardrail }
output "waf_web_acl_arn" { value = module.platform.waf_web_acl_arn }
output "certificate_arn" { value = module.platform.certificate_arn }
output "buckets" { value = module.platform.buckets }

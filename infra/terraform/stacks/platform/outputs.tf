output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "region" { value = var.region }
output "vpc_id" { value = module.vpc.vpc_id }

output "ecr_repositories" { value = module.ecr.repository_urls }

output "database" {
  value = {
    writer_endpoint = module.rds.cluster_endpoint
    reader_endpoint = module.rds.reader_endpoint
    name            = module.rds.database_name
    secret_arn      = module.rds.secret_arn
  }
  sensitive = true
}

output "buckets" { value = module.s3.bucket_names }

output "guardrail" {
  value = {
    id      = module.guardrails.guardrail_id
    version = module.guardrails.guardrail_version
  }
}

output "waf_web_acl_arn" { value = module.edge.web_acl_arn }
output "certificate_arn" { value = module.edge.certificate_arn }

output "observability" {
  value = {
    amp_remote_write = module.observability.amp_remote_write_url
    amp_workspace_id = module.observability.amp_workspace_id
    grafana_endpoint = module.observability.grafana_endpoint
    ingest_role_arn  = module.observability.ingest_role_arn
  }
}

# Consumed by ops/python/render_helm_values.py to keep GitOps values in sync
# with infrastructure outputs, so no ARN is ever hand-copied into a chart.
output "workload_role_arns" {
  value = {
    "ai-gateway"                   = module.irsa_ai_gateway.role_arn
    "agent-service"                = module.irsa_agent_service.role_arn
    "rag-service"                  = module.irsa_rag_service.role_arn
    "eval-service"                 = module.irsa_eval_service.role_arn
    "external-secrets"             = module.irsa_external_secrets.role_arn
    "aws-load-balancer-controller" = module.irsa_load_balancer_controller.role_arn
    "ebs-csi-controller-sa"        = module.irsa_ebs_csi.role_arn
  }
}

output "alert_topic_arns" { value = module.observability.alert_topic_arns }
output "backup_vault_arn" { value = module.backup.vault_arn }

output "cluster_ca" {
  value     = module.eks.cluster_ca
  sensitive = true
}

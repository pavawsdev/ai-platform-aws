###############################################################################
# Workload identities. One IRSA role per service, each scoped to exactly the
# resources that service touches. Nothing here uses a wildcard resource except
# where the AWS API genuinely has no resource-level permission.
###############################################################################
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bedrock_model_arns = [
    for m in var.allowed_bedrock_models :
    "arn:aws:bedrock:${var.region}::foundation-model/${m}"
  ]
  bedrock_inference_profile_arns = [
    for m in var.allowed_bedrock_models :
    "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*"
  ]
}

############################  ai-gateway  #####################################
data "aws_iam_policy_document" "ai_gateway" {
  statement {
    sid       = "InvokeApprovedModels"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = distinct(concat(local.bedrock_model_arns, local.bedrock_inference_profile_arns))
    condition {
      test     = "StringEquals"
      variable = "bedrock:GuardrailIdentifier"
      values   = [module.guardrails.guardrail_id]
    }
  }

  statement {
    sid       = "ApplyGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [module.guardrails.guardrail_arn]
  }

  statement {
    sid       = "InvokeSageMakerEndpoints"
    actions   = ["sagemaker:InvokeEndpoint", "sagemaker:InvokeEndpointWithResponseStream"]
    resources = ["arn:aws:sagemaker:${var.region}:${data.aws_caller_identity.current.account_id}:endpoint/${var.project}-*"]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds.secret_arn]
  }

  statement {
    sid       = "ReadProviderKeys"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.name}/providers/*"]
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [module.kms.key_arns["secrets"], module.kms.key_arns["data"]]
  }

  statement {
    sid       = "WriteAuditTrail"
    actions   = ["s3:PutObject"]
    resources = ["${module.s3.bucket_arns["audit"]}/gateway/*"]
  }

  statement {
    sid       = "PublishMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["AIPlatform/Gateway"]
    }
  }
}

module "irsa_ai_gateway" {
  source = "../../modules/iam-irsa"

  role_name                = "${local.name}-ai-gateway"
  namespace                = var.workload_namespace
  service_account          = "ai-gateway"
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_provider_url        = module.eks.oidc_provider_url
  policy_json              = data.aws_iam_policy_document.ai_gateway.json
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  tags                     = local.tags
}

############################  agent-service  ##################################
data "aws_iam_policy_document" "agent_service" {
  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds.secret_arn]
  }

  statement {
    sid       = "ReadToolCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.name}/tools/*"]
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [module.kms.key_arns["secrets"]]
  }

  # The agent may read tenant documents but must never write to them.
  statement {
    sid       = "ReadDocuments"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [module.s3.bucket_arns["documents"], "${module.s3.bucket_arns["documents"]}/*"]
  }

  statement {
    sid       = "WriteAgentTrace"
    actions   = ["s3:PutObject"]
    resources = ["${module.s3.bucket_arns["audit"]}/agent/*"]
  }
}

module "irsa_agent_service" {
  source = "../../modules/iam-irsa"

  role_name                = "${local.name}-agent-service"
  namespace                = var.workload_namespace
  service_account          = "agent-service"
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_provider_url        = module.eks.oidc_provider_url
  policy_json              = data.aws_iam_policy_document.agent_service.json
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  tags                     = local.tags
}

#############################  rag-service  ###################################
data "aws_iam_policy_document" "rag_service" {
  statement {
    sid       = "EmbedText"
    actions   = ["bedrock:InvokeModel"]
    resources = [for m in var.allowed_embedding_models : "arn:aws:bedrock:${var.region}::foundation-model/${m}"]
  }

  statement {
    sid       = "ReadWriteDocuments"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [module.s3.bucket_arns["documents"], "${module.s3.bucket_arns["documents"]}/*"]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds.secret_arn]
  }

  statement {
    sid       = "DecryptData"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.kms.key_arns["data"], module.kms.key_arns["secrets"]]
  }
}

module "irsa_rag_service" {
  source = "../../modules/iam-irsa"

  role_name                = "${local.name}-rag-service"
  namespace                = var.workload_namespace
  service_account          = "rag-service"
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_provider_url        = module.eks.oidc_provider_url
  policy_json              = data.aws_iam_policy_document.rag_service.json
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  tags                     = local.tags
}

#############################  eval-service  ##################################
data "aws_iam_policy_document" "eval_service" {
  statement {
    sid       = "InvokeJudgeModels"
    actions   = ["bedrock:InvokeModel", "bedrock:Converse"]
    resources = local.bedrock_model_arns
  }

  statement {
    sid       = "MlflowArtifacts"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [module.s3.bucket_arns["model-artifacts"], "${module.s3.bucket_arns["model-artifacts"]}/*"]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds.secret_arn]
  }

  statement {
    sid       = "DecryptData"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.kms.key_arns["data"], module.kms.key_arns["secrets"]]
  }
}

module "irsa_eval_service" {
  source = "../../modules/iam-irsa"

  role_name                = "${local.name}-eval-service"
  namespace                = var.workload_namespace
  service_account          = "eval-service"
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_provider_url        = module.eks.oidc_provider_url
  policy_json              = data.aws_iam_policy_document.eval_service.json
  permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  tags                     = local.tags
}

######################  Platform controllers (IRSA)  ##########################
data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.name}/*", module.rds.secret_arn]
  }
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name}/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [module.kms.key_arns["secrets"]]
  }
}

module "irsa_external_secrets" {
  source = "../../modules/iam-irsa"

  role_name         = "${local.name}-external-secrets"
  namespace         = "external-secrets"
  service_account   = "external-secrets"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  policy_json       = data.aws_iam_policy_document.external_secrets.json
  tags              = local.tags
}

module "irsa_load_balancer_controller" {
  source = "../../modules/iam-irsa"

  role_name         = "${local.name}-aws-lbc"
  namespace         = "kube-system"
  service_account   = "aws-load-balancer-controller"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  policy_json       = file("${path.module}/policies/aws-load-balancer-controller.json")
  tags              = local.tags
}

data "aws_iam_policy_document" "ebs_csi" {
  statement {
    actions = [
      "ec2:CreateSnapshot", "ec2:AttachVolume", "ec2:DetachVolume", "ec2:ModifyVolume",
      "ec2:DescribeAvailabilityZones", "ec2:DescribeInstances", "ec2:DescribeSnapshots",
      "ec2:DescribeTags", "ec2:DescribeVolumes", "ec2:DescribeVolumesModifications",
      "ec2:CreateVolume", "ec2:DeleteVolume", "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["kms:CreateGrant", "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:ReEncrypt*"]
    resources = [module.kms.key_arns["data"]]
  }
}

module "irsa_ebs_csi" {
  source = "../../modules/iam-irsa"

  role_name         = "${local.name}-ebs-csi"
  namespace         = "kube-system"
  service_account   = "ebs-csi-controller-sa"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  policy_json       = data.aws_iam_policy_document.ebs_csi.json
  tags              = local.tags
}

######################  Permissions boundary for workloads  ###################
# Even if someone hand-edits a workload policy, these are never grantable.
resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.name}-workload-boundary"
  description = "Hard ceiling on what any AI platform workload role can ever do"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowServiceScope"
        Effect   = "Allow"
        Action   = ["bedrock:*", "sagemaker:Invoke*", "s3:*", "secretsmanager:GetSecretValue", "kms:Decrypt", "kms:GenerateDataKey*", "cloudwatch:PutMetricData", "logs:*", "xray:Put*", "sqs:*", "aps:RemoteWrite"]
        Resource = "*"
      },
      {
        Sid      = "DenyIamAndOrgMutation"
        Effect   = "Deny"
        Action   = ["iam:*", "organizations:*", "account:*", "sts:AssumeRole"]
        Resource = "*"
      },
      {
        Sid      = "DenyDataDestruction"
        Effect   = "Deny"
        Action   = ["s3:DeleteBucket", "s3:PutBucketPolicy", "kms:ScheduleKeyDeletion", "kms:DisableKey", "rds:DeleteDBCluster", "backup:DeleteBackupVault", "eks:DeleteCluster"]
        Resource = "*"
      },
      {
        Sid      = "DenyDisablingSecurityControls"
        Effect   = "Deny"
        Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "guardduty:DeleteDetector", "guardduty:UpdateDetector", "securityhub:DisableSecurityHub", "config:DeleteConfigurationRecorder"]
        Resource = "*"
      }
    ]
  })
  tags = local.tags
}

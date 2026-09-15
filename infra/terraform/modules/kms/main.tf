###############################################################################
# Per-purpose CMKs. One key per data domain so that a compromised workload
# identity cannot decrypt data belonging to another domain, and so key
# rotation / deletion stays scoped to a blast radius we understand.
###############################################################################
locals {
  keys = {
    logs    = "AI platform log encryption (CloudWatch, VPC flow, EKS audit)"
    data    = "AI platform data at rest (S3 documents, RDS, EBS)"
    secrets = "AI platform secrets (Secrets Manager, SSM)"
    eks     = "EKS envelope encryption for Kubernetes secrets"
  }
  tags = merge(var.tags, { Module = "kms" })
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  for_each = local.keys

  statement {
    sid       = "RootAccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowAwsServices"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
      "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
    ]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "logs.${var.region}.amazonaws.com",
        "s3.amazonaws.com",
        "rds.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "ec2.amazonaws.com",
        "backup.amazonaws.com",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = local.keys

  description             = each.value
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  multi_region            = var.multi_region
  policy                  = data.aws_iam_policy_document.key[each.key].json
  tags                    = merge(local.tags, { Purpose = each.key })
}

resource "aws_kms_alias" "this" {
  for_each      = aws_kms_key.this
  name          = "alias/${var.name}-${each.key}"
  target_key_id = each.value.key_id
}

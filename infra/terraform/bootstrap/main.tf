###############################################################################
# Bootstrap: run once per account, with local state, before anything else.
# Creates the remote state backend and the GitHub Actions OIDC role, so that
# from then on nothing needs long-lived AWS credentials.
###############################################################################
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.60" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  tags = {
    Project   = var.project
    ManagedBy = "terraform-bootstrap"
    Critical  = "true"
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
  tags   = local.tags

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_dynamodb_table" "lock" {
  name         = "${var.project}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery { enabled = true }
  tags = local.tags

  lifecycle { prevent_destroy = true }
}

###############################################################################
# GitHub Actions OIDC. No access keys anywhere in CI.
###############################################################################
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.tags
}

locals {
  github_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Pinned to this repo. Environment-scoped subs mean a PR from a fork can
    # never assume the apply role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_subject_claims
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${var.project}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

# Plan-and-build role: read everything, push images, read state. It cannot
# mutate infrastructure - that is the apply role, gated on a GitHub Environment
# with required reviewers.
resource "aws_iam_role_policy" "github_plan" {
  name = "plan-and-build"
  role = aws_iam_role.github_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOnlyForPlan"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "eks:Describe*", "eks:List*", "rds:Describe*", "s3:Get*", "s3:List*", "iam:Get*", "iam:List*", "kms:Describe*", "kms:List*", "logs:Describe*", "elasticloadbalancing:Describe*", "wafv2:Get*", "wafv2:List*", "bedrock:Get*", "bedrock:List*", "backup:Describe*", "backup:List*", "aps:Describe*", "aps:List*", "grafana:Describe*", "sqs:Get*", "sqs:List*", "cloudwatch:Describe*", "budgets:View*", "ce:Get*"]
        Resource = "*"
      },
      {
        Sid      = "StateAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      },
      {
        Sid      = "StateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.lock.arn
      },
      {
        Sid      = "StateKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.state.arn
      },
      {
        Sid      = "EcrPush"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:DescribeRepositories"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "github_apply" {
  name               = "${var.project}-github-actions-apply"
  assume_role_policy = data.aws_iam_policy_document.github_apply_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "github_apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs running in a protected GitHub Environment may apply.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_apply_subject_claims
    }
  }
}

resource "aws_iam_role_policy_attachment" "github_apply" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

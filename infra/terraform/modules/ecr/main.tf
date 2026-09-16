###############################################################################
# ECR repositories, one per service.
# - Immutable tags: a deployed digest can never be silently replaced.
# - Enhanced scanning (Inspector) on push, KMS encrypted.
# - Lifecycle policy keeps cost bounded but always retains release tags.
# - Repository policy: only this account's CI role may push; only the cluster
#   node role / IRSA roles may pull.
###############################################################################
locals { tags = merge(var.tags, { Module = "ecr" }) }

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.namespace}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(local.tags, { Service = each.key })
}

resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.manage_registry_scanning ? 1 : 0
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "${var.namespace}/*"
      filter_type = "WILDCARD"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep last 50 sha-tagged (CI) images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 50
        }
        action = { type = "expire" }
      }
    ]
  })
}

data "aws_iam_policy_document" "repo" {
  statement {
    sid    = "AllowPullFromCluster"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }

  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []
    content {
      sid    = "AllowPushFromCI"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }
      actions = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy     = data.aws_iam_policy_document.repo.json
}

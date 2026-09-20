###############################################################################
# S3 buckets for the AI platform.
#   documents      - raw tenant documents ingested into RAG (CRR to DR region)
#   model-artifacts- fine-tuned adapters, eval datasets, MLflow artifact store
#   audit          - immutable governance/audit trail (Object Lock, WORM)
#   logs           - ALB / CloudTrail / access logs
# Every bucket: SSE-KMS, versioned, public access blocked, TLS-only policy.
###############################################################################
locals {
  buckets = {
    documents = {
      versioning = true
      replicate  = true
      lifecycle  = true
      object_lock = false
    }
    model-artifacts = {
      versioning = true
      replicate  = true
      lifecycle  = true
      object_lock = false
    }
    audit = {
      versioning = true
      replicate  = true
      lifecycle  = false
      object_lock = true
    }
    logs = {
      versioning = false
      replicate  = false
      lifecycle  = true
      object_lock = false
    }
  }
  tags = merge(var.tags, { Module = "s3-datalake" })
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket              = "${var.name}-${each.key}-${data.aws_caller_identity.current.account_id}"
  force_destroy       = var.force_destroy
  object_lock_enabled = each.value.object_lock
  tags                = merge(local.tags, { Dataset = each.key })
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id
  versioning_configuration {
    status = (each.value.versioning || each.value.object_lock) ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true # cuts KMS request cost ~99% on high-volume prefixes
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = local.buckets
  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.this["audit"].id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.audit_retention_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "bucket" {
  for_each = local.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this[each.key].arn,
      "${aws_s3_bucket.this[each.key].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid     = "DenyUnencryptedObjectUploads"
    effect  = "Deny"
    actions = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this[each.key].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id
  policy   = data.aws_iam_policy_document.bucket[each.key].json
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = { for k, v in local.buckets : k => v if v.lifecycle }
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

###############################################################################
# Cross-region replication for DR (RPO ~15 min via RTC)
###############################################################################
resource "aws_iam_role" "replication" {
  count              = var.enable_replication ? 1 : 0
  name               = "${var.name}-s3-replication"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "replication" {
  count = var.enable_replication ? 1 : 0
  role  = aws_iam_role.replication[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [for k, v in local.buckets : aws_s3_bucket.this[k].arn if v.replicate]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = [for k, v in local.buckets : "${aws_s3_bucket.this[k].arn}/*" if v.replicate]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = [for k, v in local.buckets : "${var.dr_bucket_arn_prefix}-${k}-${data.aws_caller_identity.current.account_id}/*" if v.replicate]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = [var.dr_kms_key_arn]
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "this" {
  for_each = var.enable_replication ? { for k, v in local.buckets : k => v if v.replicate } : {}

  role   = aws_iam_role.replication[0].arn
  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id       = "dr"
    status   = "Enabled"
    priority = 1
    filter {}

    delete_marker_replication { status = "Enabled" }

    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }

    destination {
      bucket        = "${var.dr_bucket_arn_prefix}-${each.key}-${data.aws_caller_identity.current.account_id}"
      storage_class = "STANDARD_IA"

      encryption_configuration {
        replica_kms_key_id = var.dr_kms_key_arn
      }

      replication_time {
        status = "Enabled"
        time { minutes = 15 }
      }

      metrics {
        status = "Enabled"
        event_threshold { minutes = 15 }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

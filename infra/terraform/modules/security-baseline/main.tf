###############################################################################
# Account security baseline. Everything here is "always on" and independent of
# the workload: detection, audit trail, configuration drift, and the account
# level defaults that stop an insecure resource from ever being created.
###############################################################################
locals { tags = merge(var.tags, { Module = "security-baseline" }) }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

########################  Account-level hard defaults  ########################
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  key_arn = var.data_kms_key_arn
}

resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_account_password_policy" "this" {
  count                          = var.manage_password_policy ? 1 : 0
  minimum_password_length        = 16
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
}

################################  CloudTrail  #################################
resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_iam_role" "trail" {
  name = "${var.name}-cloudtrail-to-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "trail" {
  role = aws_iam_role.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "this" {
  count = var.manage_cloudtrail ? 1 : 0

  name                          = "${var.name}-trail"
  s3_bucket_name                = var.log_bucket_name
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = var.logs_kms_key_arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail.arn

  # Data events: every read/write of tenant documents and model artifacts is
  # part of the governance audit trail, not just the control-plane calls.
  advanced_event_selector {
    name = "s3-data-events"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = var.audited_s3_arn_prefixes
    }
  }

  advanced_event_selector {
    name = "management-events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  tags = local.tags
}

##############################  GuardDuty  ####################################
resource "aws_guardduty_detector" "this" {
  count  = var.manage_guardduty ? 1 : 0
  enable = true

  datasources {
    s3_logs { enable = true }
    kubernetes {
      audit_logs { enable = true }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }

  tags = local.tags
}

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count       = var.manage_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

#############################  Security Hub  ##################################
resource "aws_securityhub_account" "this" {
  count                     = var.manage_securityhub ? 1 : 0
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = var.manage_securityhub ? toset([
    "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0",
    "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0",
  ]) : toset([])

  standards_arn = each.value
  depends_on    = [aws_securityhub_account.this]
}

##########################  IAM Access Analyzer  ##############################
resource "aws_accessanalyzer_analyzer" "this" {
  count         = var.manage_access_analyzer ? 1 : 0
  analyzer_name = "${var.name}-external-access"
  type          = "ACCOUNT"
  tags          = local.tags
}

############################  Findings routing  ###############################
resource "aws_sns_topic" "security" {
  name              = "${var.name}-security-findings"
  kms_master_key_id = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_cloudwatch_event_rule" "high_severity" {
  name        = "${var.name}-high-severity-findings"
  description = "GuardDuty + Security Hub HIGH/CRITICAL findings"
  event_pattern = jsonencode({
    source = ["aws.guardduty", "aws.securityhub"]
    detail-type = [
      "GuardDuty Finding",
      "Security Hub Findings - Imported"
    ]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
  tags = local.tags
}

resource "aws_cloudwatch_event_target" "high_severity" {
  rule      = aws_cloudwatch_event_rule.high_severity.name
  target_id = "sns"
  arn       = aws_sns_topic.security.arn
}

resource "aws_sns_topic_policy" "security" {
  arn = aws_sns_topic.security.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.security.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

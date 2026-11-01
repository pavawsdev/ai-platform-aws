###############################################################################
# AWS Backup: one plan, three rules (daily / weekly / monthly), cross-region
# copy for DR, and a vault lock so a compromised admin cannot shorten
# retention or delete recovery points.
#
# Recovery targets (see docs/dr.md):
#   Tier 1 (gateway/agent/RAG control plane)  RTO 30 min  RPO 15 min
#   Tier 2 (vector store / Aurora)            RTO  1 h    RPO  5 min (PITR)
#   Tier 3 (eval history, MLflow)             RTO 24 h    RPO 24 h
###############################################################################
locals { tags = merge(var.tags, { Module = "backup-dr" }) }

resource "aws_backup_vault" "this" {
  name        = "${var.name}-vault"
  kms_key_arn = var.kms_key_arn
  tags        = local.tags
}

resource "aws_backup_vault_lock_configuration" "this" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name   = aws_backup_vault.this.name
  changeable_for_days = var.vault_lock_changeable_for_days
  min_retention_days  = var.min_retention_days
  max_retention_days  = var.max_retention_days
}

resource "aws_iam_role" "backup" {
  name = "${var.name}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-plan"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 17 ? * * *)" # 22:30 IST
    start_window      = 60
    completion_window = 300

    lifecycle {
      delete_after = var.daily_retention_days
    }

    dynamic "copy_action" {
      for_each = var.dr_vault_arn == "" ? [] : [1]
      content {
        destination_vault_arn = var.dr_vault_arn
        lifecycle {
          delete_after = var.daily_retention_days
        }
      }
    }

    recovery_point_tags = merge(local.tags, { BackupTier = "daily" })
  }

  rule {
    rule_name         = "weekly"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 18 ? * SAT *)"
    start_window      = 60
    completion_window = 480

    lifecycle {
      cold_storage_after = 30
      delete_after       = var.weekly_retention_days
    }

    recovery_point_tags = merge(local.tags, { BackupTier = "weekly" })
  }

  rule {
    rule_name         = "monthly-compliance"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 19 1 * ? *)"
    start_window      = 60
    completion_window = 600

    lifecycle {
      cold_storage_after = 90
      delete_after       = var.monthly_retention_days
    }

    recovery_point_tags = merge(local.tags, { BackupTier = "monthly" })
  }

  advanced_backup_setting {
    backup_options = { WindowsVSS = "disabled" }
    resource_type  = "EC2"
  }

  tags = local.tags
}

# Selection by tag: any resource tagged Backup=true is protected. Kyverno and
# tflint both enforce that stateful resources carry the tag, so "forgot to add
# it to the backup plan" cannot happen silently.
resource "aws_backup_selection" "by_tag" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.name}-tagged"
  plan_id      = aws_backup_plan.this.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "true"
  }
}

resource "aws_backup_selection" "explicit" {
  count = length(var.resource_arns) > 0 ? 1 : 0

  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.name}-explicit"
  plan_id      = aws_backup_plan.this.id
  resources    = var.resource_arns
}

# Restore testing: AWS Backup runs an automated restore of a random recovery
# point every week and validates it. An untested backup is not a backup.
resource "aws_backup_restore_testing_plan" "this" {
  count = var.enable_restore_testing ? 1 : 0

  name                = replace("${var.name}_restore_test", "-", "_")
  schedule_expression = "cron(0 4 ? * MON *)"
  start_window_hours  = 4
  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = [aws_backup_vault.this.arn]
    recovery_point_types  = ["SNAPSHOT"]
    selection_window_days = 7
  }
  tags = local.tags
}

resource "aws_backup_restore_testing_selection" "aurora" {
  count = var.enable_restore_testing && length(var.restore_test_resource_arns) > 0 ? 1 : 0

  name                      = "aurora"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this[0].name
  protected_resource_type   = "Aurora"
  iam_role_arn              = aws_iam_role.backup.arn
  protected_resource_arns   = var.restore_test_resource_arns
}

resource "aws_backup_vault_notifications" "this" {
  backup_vault_name   = aws_backup_vault.this.name
  sns_topic_arn       = var.sns_topic_arn
  backup_vault_events = ["BACKUP_JOB_FAILED", "COPY_JOB_FAILED", "RESTORE_JOB_FAILED", "RESTORE_JOB_COMPLETED"]
}

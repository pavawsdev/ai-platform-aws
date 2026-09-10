output "state_bucket" { value = aws_s3_bucket.state.id }
output "lock_table" { value = aws_dynamodb_table.lock.name }
output "state_kms_alias" { value = aws_kms_alias.state.name }
output "github_plan_role_arn" { value = aws_iam_role.github_plan.arn }
output "github_apply_role_arn" { value = aws_iam_role.github_apply.arn }

output "role_arn" { value = aws_iam_role.this.arn }
output "role_name" { value = aws_iam_role.this.name }
output "service_account_annotation" {
  value = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}

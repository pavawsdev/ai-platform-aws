output "cluster_endpoint" { value = aws_rds_cluster.this.endpoint }
output "reader_endpoint" { value = aws_rds_cluster.this.reader_endpoint }
output "database_name" { value = aws_rds_cluster.this.database_name }
output "secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "security_group_id" { value = aws_security_group.db.id }
output "cluster_arn" { value = aws_rds_cluster.this.arn }

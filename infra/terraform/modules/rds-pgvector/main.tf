###############################################################################
# Aurora PostgreSQL Serverless v2 with pgvector.
# Serves three jobs:
#   1. Vector store for the RAG service (pgvector + HNSW)
#   2. Relational store for prompt registry, model registry, eval runs
#   3. Token/cost ledger for chargeback
# Chosen over OpenSearch Serverless: single datastore, ACID metadata next to
# vectors, and Serverless v2 scales to 0.5 ACU overnight (see docs/adr/0004).
###############################################################################
locals { tags = merge(var.tags, { Module = "rds-pgvector" }) }

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Aurora PostgreSQL for AI platform"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "from_cluster" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS workloads"
}

resource "aws_db_parameter_group" "instance" {
  name   = "${var.name}-aurora-pg-instance"
  family = var.parameter_group_family

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pg_cron"
    apply_method = "pending-reboot"
  }

  tags = local.tags
}

resource "aws_rds_cluster_parameter_group" "cluster" {
  name   = "${var.name}-aurora-pg-cluster"
  family = var.parameter_group_family

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  tags = local.tags
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name}/rds/master"
  description = "Aurora master credentials for the AI platform"
  kms_key_id  = var.secrets_kms_key_arn
  # Short window so a mistaken destroy in dev does not block re-create for 30d
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    engine   = "postgres"
    host     = aws_rds_cluster.this.endpoint
    reader   = aws_rds_cluster.this.reader_endpoint
    port     = 5432
    dbname   = var.database_name
  })
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${var.name}-pgvector"
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  database_name                   = var.database_name
  master_username                 = var.master_username
  master_password                 = random_password.master.result
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.cluster.name

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "17:00-18:00" # 22:30 IST, off-peak
  preferred_maintenance_window = "sun:18:30-sun:19:30"
  copy_tags_to_snapshot        = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${formatdate("YYYYMMDDhhmm", timestamp())}"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  iam_database_authentication_enabled = true

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [final_snapshot_identifier, master_password]
  }
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier                   = "${var.name}-pgvector-${count.index}"
  cluster_identifier           = aws_rds_cluster.this.id
  instance_class               = "db.serverless"
  engine                       = aws_rds_cluster.this.engine
  engine_version               = aws_rds_cluster.this.engine_version
  db_parameter_group_name      = aws_db_parameter_group.instance.name
  performance_insights_enabled = true
  performance_insights_kms_key_id = var.kms_key_arn
  monitoring_interval          = 30
  monitoring_role_arn          = aws_iam_role.monitoring.arn
  auto_minor_version_upgrade   = true
  # index 0 is writer; the rest are readers in other AZs
  promotion_tier = count.index
  tags           = local.tags
}

resource "aws_iam_role" "monitoring" {
  name = "${var.name}-rds-enhanced-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

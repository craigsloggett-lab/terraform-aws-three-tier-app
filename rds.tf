resource "aws_db_subnet_group" "database" {
  count = local.database_enabled ? 1 : 0

  name       = var.database.name
  subnet_ids = values(var.vpc.database_subnet_ids)

  tags = merge(var.tags, { Name = var.database.name })
}

resource "aws_db_instance" "database" {
  count = local.database_enabled ? 1 : 0

  identifier     = var.database.name
  engine         = "postgres"
  engine_version = var.database.engine_version
  instance_class = var.database.instance_class

  allocated_storage = var.database.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.database.kms_key_arn

  db_name  = var.database.db_name
  username = var.database.username
  port     = var.database.port

  # RDS generates and rotates the password in Secrets Manager, so it never enters config or state.
  manage_master_user_password         = true
  master_user_secret_kms_key_id       = var.database.master_user_secret_kms_key_arn
  iam_database_authentication_enabled = true

  multi_az               = var.database.multi_az
  db_subnet_group_name   = aws_db_subnet_group.database[0].name
  vpc_security_group_ids = [aws_security_group.database[0].id]
  publicly_accessible    = false

  backup_retention_period    = var.database.backup_retention_period
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  # Defaults to true (variables.tf). Trivy sees false only via examples/public-https,
  # which disables it so the example destroys cleanly.
  #trivy:ignore:AWS-0177
  deletion_protection       = var.database.deletion_protection
  skip_final_snapshot       = var.database.skip_final_snapshot
  final_snapshot_identifier = local.database_final_snapshot_identifier

  tags = merge(var.tags, { Name = var.database.name })
}

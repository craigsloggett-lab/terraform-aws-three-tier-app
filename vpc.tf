# Security groups (one per tier)

resource "aws_security_group" "web" {
  name_prefix = "${var.web.name}-"
  description = "Load balancer security group for ${var.web.name}"
  vpc_id      = var.vpc.vpc_id

  tags = merge(var.tags, { Name = var.web.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.app.name}-"
  description = "App server security group for ${var.app.name}"
  vpc_id      = var.vpc.vpc_id

  tags = merge(var.tags, { Name = var.app.name })

  lifecycle {
    create_before_destroy = true
  }
}

# No egress rules are defined for the database group, so Terraform removes the AWS default allow-all egress.
resource "aws_security_group" "database" {
  count = local.database_enabled ? 1 : 0

  name_prefix = "${var.database.name}-"
  description = "Database security group for ${var.database.name}"
  vpc_id      = var.vpc.vpc_id

  tags = merge(var.tags, { Name = var.database.name })

  lifecycle {
    create_before_destroy = true
  }
}

# Web tier rules

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP from the internet to the load balancer"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = var.web.name })
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  count = local.https_enabled ? 1 : 0

  security_group_id = aws_security_group.web.id
  description       = "HTTPS from the internet to the load balancer"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = var.web.name })
}

resource "aws_vpc_security_group_egress_rule" "web_to_app" {
  security_group_id            = aws_security_group.web.id
  description                  = "Load balancer to app servers on the application port"
  ip_protocol                  = "tcp"
  from_port                    = var.app.port
  to_port                      = var.app.port
  referenced_security_group_id = aws_security_group.app.id

  tags = merge(var.tags, { Name = var.web.name })
}

# App tier rules

resource "aws_vpc_security_group_ingress_rule" "app_from_web" {
  security_group_id            = aws_security_group.app.id
  description                  = "App servers from the load balancer on the application port"
  ip_protocol                  = "tcp"
  from_port                    = var.app.port
  to_port                      = var.app.port
  referenced_security_group_id = aws_security_group.web.id

  tags = merge(var.tags, { Name = var.app.name })
}

# User-directed egress for SSM, Secrets Manager and package repositories on 443 only (clarification Q2).
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS from app servers to AWS APIs and package repositories"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = var.app.name })
}

resource "aws_vpc_security_group_egress_rule" "app_to_database" {
  count = local.database_enabled ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "App servers to the database on the database port"
  ip_protocol                  = "tcp"
  from_port                    = var.database.port
  to_port                      = var.database.port
  referenced_security_group_id = aws_security_group.database[0].id

  tags = merge(var.tags, { Name = var.app.name })
}

# Data tier rules

resource "aws_vpc_security_group_ingress_rule" "database_from_app" {
  count = local.database_enabled ? 1 : 0

  security_group_id            = aws_security_group.database[0].id
  description                  = "Database from app servers on the database port"
  ip_protocol                  = "tcp"
  from_port                    = var.database.port
  to_port                      = var.database.port
  referenced_security_group_id = aws_security_group.app.id

  tags = merge(var.tags, { Name = var.database.name })
}

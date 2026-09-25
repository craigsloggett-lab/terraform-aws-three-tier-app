# AWS-0053: the web tier is internet-facing by design (FR-02); only the listener ports are open to the internet.
# AWS-0052: drop_invalid_header_fields was not selected by the user in clarification Q1; see design.md §7 OQ-1 (resolve before release).
#trivy:ignore:AWS-0053
#trivy:ignore:AWS-0052
resource "aws_lb" "web" {
  name               = var.web.name
  internal           = false
  load_balancer_type = "application"
  subnets            = values(var.vpc.public_subnet_ids)
  security_groups    = [aws_security_group.web.id]

  tags = merge(var.tags, { Name = var.web.name })
}

resource "aws_lb_target_group" "app" {
  name_prefix = local.target_group_name_prefix
  port        = var.app.port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc.vpc_id

  health_check {
    path     = var.app.health_check_path
    protocol = "HTTP"
    matcher  = "200"
  }

  tags = merge(var.tags, { Name = var.app.name })

  lifecycle {
    create_before_destroy = true
  }
}

# Plain HTTP is forwarded only when the caller supplies no certificate (user-directed, FR-03); with a certificate this listener only redirects to HTTPS.
#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.app.arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = merge(var.tags, { Name = var.web.name })
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.web.ssl_policy
  certificate_arn   = var.web.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = merge(var.tags, { Name = var.web.name })
}

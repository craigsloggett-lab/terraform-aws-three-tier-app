# Auto Scaling Group

resource "aws_autoscaling_group" "app" {
  name                      = var.app.name
  min_size                  = var.app.min_size
  max_size                  = var.app.max_size
  vpc_zone_identifier       = values(var.vpc.private_subnet_ids)
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = var.app.health_check_grace_period

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 90
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.app.name })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

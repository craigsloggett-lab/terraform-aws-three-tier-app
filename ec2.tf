resource "aws_launch_template" "app" {
  # The provider requires name_prefix >= 3 characters, but A1/A2 allow a 1-character app.name, so pad that case only.
  name_prefix            = length(var.app.name) < 2 ? "${var.app.name}-lt-" : "${var.app.name}-"
  image_id               = data.aws_ami.selected.id
  instance_type          = var.app.instance_type
  update_default_version = true
  user_data              = var.app.user_data == null ? null : base64encode(var.app.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.app.id]
  }

  block_device_mappings {
    device_name = data.aws_ami.selected.root_device_name

    ebs {
      volume_size           = var.app.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.app.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  # ASG tags never reach volumes, so the launch template tags them (instances are tagged by the ASG).
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = var.app.name })
  }

  tags = merge(var.tags, { Name = var.app.name })

  lifecycle {
    create_before_destroy = true
  }
}

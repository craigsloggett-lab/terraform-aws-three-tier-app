resource "aws_iam_role" "app" {
  name = var.app.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      },
    ]
  })

  tags = merge(var.tags, { Name = var.app.name })
}

resource "aws_iam_instance_profile" "app" {
  name = var.app.name
  role = aws_iam_role.app.name

  tags = merge(var.tags, { Name = var.app.name })
}

resource "aws_iam_role_policy_attachment" "app" {
  for_each = var.app.managed_policy_arns

  role       = aws_iam_role.app.name
  policy_arn = each.value
}

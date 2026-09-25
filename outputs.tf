output "alb_arn" {
  description = "ARN of the load balancer."
  value       = aws_lb.web.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix of the load balancer, for CloudWatch metric dimensions."
  value       = aws_lb.web.arn_suffix
}

output "alb_dns_name" {
  description = "DNS name of the load balancer. Point a CNAME or alias record at it."
  value       = aws_lb.web.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the load balancer, for Route 53 alias records."
  value       = aws_lb.web.zone_id
}

output "http_listener_arn" {
  description = "ARN of the port-80 listener (redirects when HTTPS is enabled, forwards otherwise)."
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "ARN of the port-443 listener. Attach extra certificates or rules to it. Null without a certificate."
  value       = try(aws_lb_listener.https[0].arn, null)
}

output "target_group_arn" {
  description = "ARN of the app target group."
  value       = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group, for CloudWatch metric dimensions."
  value       = aws_lb_target_group.app.arn_suffix
}

output "web_security_group_id" {
  description = "ID of the load balancer security group."
  value       = aws_security_group.web.id
}

output "app_security_group_id" {
  description = "ID of the app server security group. Reference it to allow app access to other services."
  value       = aws_security_group.app.id
}

output "autoscaling_group_name" {
  description = "Name of the ASG. Attach scaling policies to it."
  value       = aws_autoscaling_group.app.name
}

output "autoscaling_group_arn" {
  description = "ARN of the ASG."
  value       = aws_autoscaling_group.app.arn
}

output "launch_template_id" {
  description = "ID of the launch template."
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Latest launch template version, which is the version the ASG runs."
  value       = aws_launch_template.app.latest_version
}

output "iam_role_name" {
  description = "Name of the instance role. Attach extra policies to it."
  value       = aws_iam_role.app.name
}

output "iam_role_arn" {
  description = "ARN of the instance role."
  value       = aws_iam_role.app.arn
}

output "iam_instance_profile_arn" {
  description = "ARN of the instance profile."
  value       = aws_iam_instance_profile.app.arn
}

output "ami_id" {
  description = "ID of the AMI the launch template currently uses."
  value       = data.aws_ami.selected.id
}

output "db_instance_identifier" {
  description = "RDS instance identifier. Null without a data tier."
  value       = try(aws_db_instance.database[0].identifier, null)
}

output "db_instance_arn" {
  description = "RDS instance ARN. Null without a data tier."
  value       = try(aws_db_instance.database[0].arn, null)
}

output "db_instance_address" {
  description = "Database hostname. Null without a data tier."
  value       = try(aws_db_instance.database[0].address, null)
}

output "db_instance_endpoint" {
  description = "Database host:port. Null without a data tier."
  value       = try(aws_db_instance.database[0].endpoint, null)
}

output "db_instance_port" {
  description = "Database port. Null without a data tier."
  value       = try(aws_db_instance.database[0].port, null)
}

output "db_instance_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials. Grant secretsmanager:GetSecretValue on it (and kms:Decrypt on its key) to readers. Null without a data tier."
  value       = try(aws_db_instance.database[0].master_user_secret[0].secret_arn, null)
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group. Null without a data tier."
  value       = try(aws_db_subnet_group.database[0].name, null)
}

output "database_security_group_id" {
  description = "ID of the database security group. Null without a data tier."
  value       = try(aws_security_group.database[0].id, null)
}

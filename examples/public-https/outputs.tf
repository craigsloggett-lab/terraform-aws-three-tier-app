output "alb_dns_name" {
  description = "DNS name of the load balancer. Point a CNAME or alias record for the certificate's domain at it."
  value       = module.three_tier_app.alb_dns_name
}

output "db_instance_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the database master credentials."
  value       = module.three_tier_app.db_instance_master_user_secret_arn
}

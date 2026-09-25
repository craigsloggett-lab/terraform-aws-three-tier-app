# Required

variable "certificate_arn" {
  description = "ARN of an issued ACM certificate in `region` for the load balancer's HTTPS listener."
  type        = string
}

variable "region" {
  description = "AWS region to deploy into, for example `us-east-1`. It must have at least two availability zones."
  type        = string
}

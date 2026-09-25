# Integration tests: real AWS provider, apply then destroy.
#
# Run in CI or a sandbox account with credentials, TF_VAR_region and TF_VAR_vpc
# (real VPC and subnet IDs) set. Creates billable resources, which Terraform
# destroys at the end of the run. Not run as part of the unit test suite:
#   terraform test -filter=tests/integration.tftest.hcl

provider "aws" {
  region = var.region
}

variables {
  web = {
    name = "tta-int-web"
  }
  app = {
    name     = "tta-int-app"
    min_size = 1
    max_size = 1
  }
  database = {
    name                    = "tta-int-db"
    multi_az                = false
    deletion_protection     = false
    skip_final_snapshot     = true
    backup_retention_period = 1
  }
}

# Scenario: "End-to-End" - apply_http_with_database
# integration
run "apply_http_with_database" {
  command = apply

  assert {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:elasticloadbalancing:", output.alb_arn))
    error_message = "The alb_arn output must be a real Elastic Load Balancing ARN."
  }

  # Moved from unit_basic tags_and_outputs [plan-unknown].
  assert {
    condition     = endswith(output.alb_dns_name, ".elb.amazonaws.com")
    error_message = "The alb_dns_name output must be the ALB's AWS-assigned DNS name."
  }

  # Moved from unit_basic app_tier_defaults [plan-unknown].
  assert {
    condition     = aws_autoscaling_group.app.launch_template[0].version == tostring(aws_launch_template.app.latest_version)
    error_message = "The ASG must run the launch template's latest version."
  }

  assert {
    condition     = output.launch_template_latest_version == 1
    error_message = "A freshly created launch template must be at version 1."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].target_group_arn == aws_lb_target_group.app.arn
    error_message = "Without a certificate, the HTTP listener must forward to the real target group."
  }

  # Moved from unit_complete full_features_outputs [plan-unknown].
  assert {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:secretsmanager:", output.db_instance_master_user_secret_arn))
    error_message = "The db_instance_master_user_secret_arn output must be a real Secrets Manager ARN."
  }

  # Moved from unit_complete full_features_outputs [plan-unknown].
  assert {
    condition     = endswith(output.db_instance_endpoint, ":5432")
    error_message = "The db_instance_endpoint output must end with the database port (:5432)."
  }

  assert {
    condition     = aws_db_instance.database[0].storage_encrypted == true
    error_message = "The DB instance must be encrypted at rest in AWS."
  }

  assert {
    condition     = aws_db_instance.database[0].publicly_accessible == false
    error_message = "The DB instance must not be publicly accessible in AWS."
  }

  assert {
    condition     = can(regex("^sg-", output.app_security_group_id))
    error_message = "The app_security_group_id output must be a real security group ID."
  }

  # Moved from unit_complete full_features_web [plan-unknown]. Without a
  # certificate the HTTPS listener is not created, so its output is null.
  assert {
    condition     = output.https_listener_arn == null
    error_message = "Without web.certificate_arn, the https_listener_arn output must be null."
  }
}

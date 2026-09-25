# Generated from specs/003-three-tier-app/design.md Section 5
# Scenario: "Feature Interactions (edge cases)" - non-obvious toggle
# combinations and precedence behave correctly. Unit test: mock provider,
# plan only.

# --- Shared unit-test fixture (design.md Section 5) ---

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id               = "ami-0123456789abcdef0"
      architecture     = "x86_64"
      root_device_name = "/dev/xvda"
    }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
    }
  }
  mock_data "aws_subnets" {
    defaults = {
      ids = [
        "subnet-0000000000000000a", "subnet-0000000000000000b",
        "subnet-0000000000000001a", "subnet-0000000000000001b",
        "subnet-0000000000000002a", "subnet-0000000000000002b",
      ]
    }
  }
}

override_resource {
  target          = aws_security_group.web
  override_during = plan
  values          = { id = "sg-0000000000000web0" }
}
override_resource {
  target          = aws_security_group.app
  override_during = plan
  values          = { id = "sg-0000000000000app0" }
}
override_resource {
  target          = aws_security_group.database
  override_during = plan
  values          = { id = "sg-00000000000000db0" }
}
override_resource {
  target          = aws_lb_target_group.app
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/0123456789abcdef" }
}
override_resource {
  target          = aws_iam_instance_profile.app
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:instance-profile/three-tier-app" }
}

variables {
  vpc = {
    vpc_id              = "vpc-0123456789abcdef0"
    public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
    private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
    database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
  }
}

# --- Runs ---

# Scenario: "Feature Interactions - HTTPS without a data tier"
run "https_without_database" {
  command = plan

  variables {
    web = { certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc" }
  }

  assert {
    condition     = length(aws_lb_listener.https) == 1
    error_message = "An HTTPS listener must be created when web.certificate_arn is set, even without a data tier."
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "The HTTPS listener must default to ELBSecurityPolicy-TLS13-1-2-2021-06."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect"
    error_message = "With a certificate, the HTTP listener must redirect."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].target_group_arn == null
    error_message = "With a certificate, the HTTP listener must stop forwarding to the target group."
  }

  assert {
    condition     = length(aws_db_instance.database) == 0
    error_message = "No DB instance may be created when database is null."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.app_to_database) == 0
    error_message = "No app-to-database egress rule may exist without a data tier."
  }
}

# Scenario: "Feature Interactions - Data tier without HTTPS"
run "database_without_https" {
  command = plan

  variables {
    database = {}
  }

  assert {
    condition     = length(aws_db_instance.database) == 1
    error_message = "database = {} must create the DB instance with all defaults."
  }

  assert {
    condition     = length(aws_db_subnet_group.database) == 1
    error_message = "database = {} must create the DB subnet group."
  }

  assert {
    condition     = length(aws_security_group.database) == 1
    error_message = "database = {} must create the database security group."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.database_from_app) == 1
    error_message = "database = {} must create the database ingress rule from the app tier."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.app_to_database) == 1
    error_message = "database = {} must create the app-to-database egress rule."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_to_database[0].from_port == 5432
    error_message = "App-to-database egress must default to port 5432."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "Without a certificate, the HTTP listener must still forward when a data tier exists."
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "No HTTPS listener may be created without a certificate."
  }

  assert {
    condition     = aws_db_instance.database[0].engine_version == "16"
    error_message = "The DB engine version must default to \"16\"."
  }

  assert {
    condition     = aws_db_instance.database[0].username == "app_admin"
    error_message = "The DB master username must default to app_admin (not postgres)."
  }
}

# Scenario: "Feature Interactions - Resilience relaxed, security unchanged"
run "database_protections_relaxed" {
  command = plan

  variables {
    database = {
      multi_az                = false
      deletion_protection     = false
      skip_final_snapshot     = true
      backup_retention_period = 1
    }
  }

  assert {
    condition     = aws_db_instance.database[0].multi_az == false
    error_message = "database.multi_az = false must produce a single-AZ instance."
  }

  assert {
    condition     = aws_db_instance.database[0].deletion_protection == false
    error_message = "database.deletion_protection = false must turn deletion protection off."
  }

  assert {
    condition     = aws_db_instance.database[0].skip_final_snapshot == true
    error_message = "database.skip_final_snapshot = true must be honoured."
  }

  assert {
    condition     = aws_db_instance.database[0].backup_retention_period == 1
    error_message = "database.backup_retention_period = 1 (the minimum) must be honoured."
  }

  assert {
    condition     = aws_db_instance.database[0].storage_encrypted == true
    error_message = "DB storage encryption must remain on when resilience settings are relaxed."
  }

  assert {
    condition     = aws_db_instance.database[0].publicly_accessible == false
    error_message = "The DB instance must remain private when resilience settings are relaxed."
  }

  assert {
    condition     = aws_db_instance.database[0].manage_master_user_password == true
    error_message = "The DB master password must remain managed when resilience settings are relaxed."
  }
}

# Scenario: "Feature Interactions - Consumer Name tag cannot override module names"
run "consumer_name_tag_is_overridden" {
  command = plan

  variables {
    tags     = { Name = "consumer", Environment = "dev" }
    database = {}
  }

  assert {
    condition     = aws_lb.web.tags["Name"] == "three-tier-app-web"
    error_message = "The ALB Name tag must be web.name, not the consumer-supplied Name tag."
  }

  assert {
    condition     = aws_security_group.app.tags["Name"] == "three-tier-app"
    error_message = "The app security group Name tag must be app.name, not the consumer-supplied Name tag."
  }

  assert {
    condition     = aws_db_instance.database[0].tags["Name"] == "three-tier-app-db"
    error_message = "The DB instance Name tag must be database.name, not the consumer-supplied Name tag."
  }

  # aws_autoscaling_group.tag is a set: filter with for and one(), never [0]
  assert {
    condition     = one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Name"]) == "three-tier-app"
    error_message = "The instance Name tag emitted by the ASG must be app.name, not the consumer-supplied Name tag."
  }

  assert {
    condition     = aws_lb.web.tags["Environment"] == "dev"
    error_message = "Consumer tags other than Name must be kept."
  }
}

# Scenario: "Feature Interactions - No managed policies"
run "no_managed_policies" {
  command = plan

  variables {
    app = { managed_policy_arns = {} }
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.app) == 0
    error_message = "An empty app.managed_policy_arns map must attach no policies."
  }

  assert {
    condition     = aws_iam_role.app.name == "three-tier-app"
    error_message = "The app role must still be created with no managed policies."
  }

  assert {
    condition     = aws_launch_template.app.iam_instance_profile[0].arn == "arn:aws:iam::123456789012:instance-profile/three-tier-app"
    error_message = "The instance profile must still be attached to the launch template with no managed policies."
  }
}

# Scenario: "Feature Interactions - Data-backed checks fail loudly" (AMI architecture)
run "ami_architecture_mismatch" {
  command = plan

  override_data {
    target = data.aws_ami.selected
    values = {
      id               = "ami-0123456789abcdef0"
      architecture     = "arm64"
      root_device_name = "/dev/xvda"
    }
  }

  expect_failures = [check.ami_architecture]

  assert {
    condition     = aws_launch_template.app.instance_type == "t3.micro"
    error_message = "The plan must still build the launch template when the architecture check fails."
  }
}

# Scenario: "Feature Interactions - Data-backed checks fail loudly" (subnets in VPC)
run "subnet_outside_vpc" {
  command = plan

  override_data {
    target = data.aws_subnets.in_vpc
    values = {
      ids = ["subnet-0000000000000000a"]
    }
  }

  expect_failures = [check.subnets_in_vpc]

  assert {
    condition     = length(aws_db_instance.database) == 0
    error_message = "The plan must still complete (with no data tier) when the subnets-in-VPC check fails."
  }
}

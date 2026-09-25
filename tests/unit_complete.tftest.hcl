# Generated from specs/003-three-tier-app/design.md Section 5
# Scenario: "Full Features (complete)" - with every optional input set, all
# conditional resources exist, all overrides take effect, and every security
# control still holds. Unit test: mock provider, plan only.

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

# Fixture `vpc` plus the full-features inputs (a file may hold only one
# variables block, so both are merged here).
variables {
  vpc = {
    vpc_id              = "vpc-0123456789abcdef0"
    public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
    private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
    database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
  }
  web = {
    name            = "complete-web"
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
  }
  app = {
    name                      = "complete-app"
    instance_type             = "t3.small"
    port                      = 8443
    health_check_path         = "/healthz"
    health_check_grace_period = 600
    min_size                  = 3
    max_size                  = 6
    root_volume_size          = 50
    user_data                 = "#!/bin/bash\necho ready"
    ebs_kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-1111-2222-3333-444444444444"
    managed_policy_arns = {
      ssm     = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      secrets = "arn:aws:iam::123456789012:policy/complete-app-secrets"
    }
  }
  ami = {
    owners       = ["amazon"]
    name_pattern = "al2023-ami-2023.*-x86_64"
  }
  database = {
    name                           = "complete-db"
    engine_version                 = "17"
    instance_class                 = "db.t4g.small"
    allocated_storage              = 50
    db_name                        = "orders"
    username                       = "orders_admin"
    port                           = 5433
    multi_az                       = true
    backup_retention_period        = 14
    deletion_protection            = true
    skip_final_snapshot            = false
    kms_key_arn                    = "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-1111-2222-3333-444444444444"
    master_user_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/cccccccc-1111-2222-3333-444444444444"
  }
  tags = {
    Environment = "test"
    CostCenter  = "1234"
  }
}

# --- Runs ---

# Scenario: "Full Features (complete)" - full_features_web
run "full_features_web" {
  command = plan

  assert {
    condition     = length(aws_lb_listener.https) == 1
    error_message = "An HTTPS listener must be created when web.certificate_arn is set."
  }

  assert {
    condition     = aws_lb_listener.https[0].port == 443
    error_message = "The HTTPS listener must listen on port 443."
  }

  assert {
    condition     = aws_lb_listener.https[0].protocol == "HTTPS"
    error_message = "The port-443 listener must use the HTTPS protocol."
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    error_message = "The HTTPS listener must use the caller-supplied web.ssl_policy."
  }

  assert {
    condition     = aws_lb_listener.https[0].certificate_arn == "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    error_message = "The HTTPS listener must use web.certificate_arn."
  }

  assert {
    condition     = aws_lb_listener.https[0].default_action[0].target_group_arn == aws_lb_target_group.app.arn
    error_message = "The HTTPS listener must forward to the app target group."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect"
    error_message = "With a certificate, the HTTP listener default action must be redirect."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
    error_message = "The HTTP listener must redirect to HTTPS."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].redirect[0].port == "443"
    error_message = "The HTTP redirect must target port \"443\" (string-typed)."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"
    error_message = "The HTTP redirect must be permanent (HTTP_301)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_https[0].from_port == 443
    error_message = "A 443 ingress rule must exist on the web security group when HTTPS is enabled."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_https[0].cidr_ipv4 == "0.0.0.0/0"
    error_message = "The web HTTPS ingress rule must allow the internet (0.0.0.0/0)."
  }

  assert {
    condition     = aws_lb_target_group.app.port == 8443
    error_message = "The target group port must follow app.port (8443)."
  }

  assert {
    condition     = aws_lb_target_group.app.health_check[0].path == "/healthz"
    error_message = "The target group health check path must follow app.health_check_path (/healthz)."
  }

  assert {
    condition     = aws_lb_target_group.app.name_prefix == "comple"
    error_message = "The target group name_prefix must be the first 6 characters of app.name (comple)."
  }

  # [plan-unknown] "HTTPS listener ARN output" (output.https_listener_arn) is
  # unknown at plan and is asserted in the integration test instead.
}

# Scenario: "Full Features (complete)" - full_features_app
run "full_features_app" {
  command = plan

  assert {
    condition     = aws_launch_template.app.user_data == base64encode("#!/bin/bash\necho ready")
    error_message = "The launch template user data must be app.user_data base64-encoded."
  }

  assert {
    condition     = base64decode(aws_launch_template.app.user_data) == "#!/bin/bash\necho ready"
    error_message = "The launch template user data must decode back to app.user_data unchanged."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-1111-2222-3333-444444444444"
    error_message = "The root volume must use app.ebs_kms_key_arn when supplied."
  }

  # ebs.encrypted is string-typed in provider 5.x
  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "The root volume must remain encrypted when a CMK is supplied."
  }

  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must remain required with all features enabled."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 50
    error_message = "The root volume size must follow app.root_volume_size (50 GiB)."
  }

  assert {
    condition     = aws_launch_template.app.instance_type == "t3.small"
    error_message = "The instance type must follow app.instance_type (t3.small)."
  }

  assert {
    condition     = aws_autoscaling_group.app.min_size == 3
    error_message = "The ASG min_size must follow app.min_size (3)."
  }

  assert {
    condition     = aws_autoscaling_group.app.max_size == 6
    error_message = "The ASG max_size must follow app.max_size (6)."
  }

  assert {
    condition     = aws_autoscaling_group.app.health_check_grace_period == 600
    error_message = "The ASG grace period must follow app.health_check_grace_period (600)."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.app) == 2
    error_message = "Both caller-supplied managed policies must be attached."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.app["secrets"].policy_arn == "arn:aws:iam::123456789012:policy/complete-app-secrets"
    error_message = "The extra managed policy must be attached under its static key (secrets)."
  }

  # aws_autoscaling_group.tag is a set: filter with for and one(), never [0]
  assert {
    condition     = one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Environment"]) == "test"
    error_message = "Consumer tags must be emitted on the ASG for propagation to instances."
  }
}

# Scenario: "Full Features (complete)" - full_features_database
run "full_features_database" {
  command = plan

  assert {
    condition     = length(aws_db_instance.database) == 1
    error_message = "Exactly one DB instance must be created when database is set."
  }

  assert {
    condition     = aws_db_instance.database[0].engine == "postgres"
    error_message = "The DB engine must be postgres."
  }

  assert {
    condition     = aws_db_instance.database[0].engine_version == "17"
    error_message = "The DB engine version must follow database.engine_version (17)."
  }

  assert {
    condition     = aws_db_instance.database[0].identifier == "complete-db"
    error_message = "The DB identifier must follow database.name (complete-db)."
  }

  assert {
    condition     = aws_db_instance.database[0].storage_encrypted == true
    error_message = "DB storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.database[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-1111-2222-3333-444444444444"
    error_message = "DB storage must use database.kms_key_arn when supplied."
  }

  assert {
    condition     = aws_db_instance.database[0].publicly_accessible == false
    error_message = "The DB instance must never be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.database[0].manage_master_user_password == true
    error_message = "The DB master password must be managed by Secrets Manager (never in state)."
  }

  assert {
    condition     = aws_db_instance.database[0].master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/cccccccc-1111-2222-3333-444444444444"
    error_message = "The master user secret must use database.master_user_secret_kms_key_arn when supplied."
  }

  assert {
    condition     = aws_db_instance.database[0].iam_database_authentication_enabled == true
    error_message = "IAM database authentication must be enabled (RDS.10)."
  }

  assert {
    condition     = aws_db_instance.database[0].multi_az == true
    error_message = "The DB instance must be Multi-AZ when database.multi_az is true."
  }

  assert {
    condition     = aws_db_instance.database[0].backup_retention_period == 14
    error_message = "DB backup retention must follow database.backup_retention_period (14)."
  }

  assert {
    condition     = aws_db_instance.database[0].deletion_protection == true
    error_message = "DB deletion protection must be on when database.deletion_protection is true."
  }

  assert {
    condition     = aws_db_instance.database[0].skip_final_snapshot == false
    error_message = "A final snapshot must be kept when database.skip_final_snapshot is false."
  }

  assert {
    condition     = aws_db_instance.database[0].final_snapshot_identifier == "complete-db-final"
    error_message = "The final snapshot identifier must be derived as <database.name>-final."
  }

  assert {
    condition     = aws_db_instance.database[0].copy_tags_to_snapshot == true
    error_message = "Tags must be copied to DB snapshots (RDS.17)."
  }

  assert {
    condition     = aws_db_instance.database[0].auto_minor_version_upgrade == true
    error_message = "Automatic minor version upgrades must be enabled (RDS.13)."
  }

  assert {
    condition     = aws_db_instance.database[0].storage_type == "gp3"
    error_message = "DB storage must be gp3."
  }

  assert {
    condition     = aws_db_instance.database[0].username == "orders_admin"
    error_message = "The DB master username must follow database.username (orders_admin)."
  }

  assert {
    condition     = aws_db_instance.database[0].port == 5433
    error_message = "The DB port must follow database.port (5433)."
  }

  assert {
    condition     = contains(aws_db_instance.database[0].vpc_security_group_ids, "sg-00000000000000db0")
    error_message = "The DB instance must use the database security group."
  }

  assert {
    condition     = aws_db_subnet_group.database[0].subnet_ids == toset(["subnet-0000000000000002a", "subnet-0000000000000002b"])
    error_message = "The DB subnet group must contain only vpc.database_subnet_ids."
  }

  assert {
    condition     = aws_db_subnet_group.database[0].name == "complete-db"
    error_message = "The DB subnet group name must follow database.name (complete-db)."
  }
}

# Scenario: "Full Features (complete)" - full_features_network
run "full_features_network" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_to_database[0].referenced_security_group_id == aws_security_group.database[0].id
    error_message = "App-to-database egress must target the database security group."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_to_database[0].security_group_id == "sg-0000000000000app0"
    error_message = "The app-to-database egress rule must be on the app security group."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_to_database[0].from_port == 5433
    error_message = "App-to-database egress must be on database.port (5433)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_app[0].referenced_security_group_id == "sg-0000000000000app0"
    error_message = "Database ingress must come only from the app security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_app[0].security_group_id == "sg-00000000000000db0"
    error_message = "The database ingress rule must be on the database security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_app[0].to_port == 5433
    error_message = "Database ingress must be on database.port (5433)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.web_to_app.from_port == 8443
    error_message = "Web egress must follow app.port (8443)."
  }

  assert {
    condition     = aws_security_group.database[0].vpc_id == "vpc-0123456789abcdef0"
    error_message = "The database security group must be created in vpc.vpc_id."
  }
}

# Scenario: "Full Features (complete)" - full_features_outputs
run "full_features_outputs" {
  command = plan

  assert {
    condition     = output.db_instance_identifier == "complete-db"
    error_message = "The db_instance_identifier output must be database.name (complete-db)."
  }

  assert {
    condition     = output.db_instance_port == 5433
    error_message = "The db_instance_port output must be database.port (5433)."
  }

  assert {
    condition     = output.db_subnet_group_name == "complete-db"
    error_message = "The db_subnet_group_name output must be database.name (complete-db)."
  }

  assert {
    condition     = output.database_security_group_id == "sg-00000000000000db0"
    error_message = "The database_security_group_id output must be the database security group ID."
  }

  assert {
    condition     = aws_db_instance.database[0].tags["Name"] == "complete-db"
    error_message = "The DB instance Name tag must be database.name, merged over consumer tags."
  }

  assert {
    condition     = aws_db_instance.database[0].tags["CostCenter"] == "1234"
    error_message = "Consumer tags must be merged onto the DB instance."
  }

  # [plan-unknown] "Secret ARN output" (output.db_instance_master_user_secret_arn)
  # and "Endpoint output" (output.db_instance_endpoint) are unknown at plan and
  # are asserted in the integration test instead.
}

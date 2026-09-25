# Generated from specs/003-three-tier-app/design.md Section 5
# Scenarios: "Validation Boundaries (accept)" followed by "Validation Errors
# (reject)". Accept runs come first: an unexpected error in a run skips every
# later run in the same file. Unit test: mock provider, plan only.
#
# Long strings: S(n) in the design is join("", [for i in range(n) : "a"]) for
# n <= 1024. Longer strings nest join() because range() is capped at 1024.

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

# --- Boundary-pass cases (validation accepts) ---

# Scenario: "Validation Boundaries (accept)" - accepts_lower_boundaries
# The fixture vpc has exactly 2 public, 2 private and 2 database subnets, the
# minimum for V2, V4 and D1.
run "accepts_lower_boundaries" {
  command = plan

  variables {
    web = { name = "a" }
    app = {
      name                      = "a"
      port                      = 1
      health_check_path         = "/"
      health_check_grace_period = 0
      min_size                  = 0
      max_size                  = 1
      root_volume_size          = 8
      managed_policy_arns       = {}
    }
    database = {
      name                    = "a"
      engine_version          = "15"
      allocated_storage       = 20
      db_name                 = "a"
      username                = "a"
      port                    = 1150
      backup_retention_period = 1
    }
  }

  assert {
    condition     = aws_lb.web.name == "a"
    error_message = "A 1-character web.name (lower boundary of W1/W2) must be accepted."
  }

  assert {
    condition     = aws_lb_target_group.app.port == 1
    error_message = "app.port = 1 (lower boundary of A4) must be accepted."
  }

  assert {
    condition     = aws_autoscaling_group.app.min_size == 0
    error_message = "app.min_size = 0 (lower boundary of A8) must be accepted."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 8
    error_message = "app.root_volume_size = 8 (lower boundary of A11) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].port == 1150
    error_message = "database.port = 1150 (lower boundary of D11) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].backup_retention_period == 1
    error_message = "database.backup_retention_period = 1 (lower boundary of D12) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].allocated_storage == 20
    error_message = "database.allocated_storage = 20 (lower boundary of D7) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].engine_version == "15"
    error_message = "database.engine_version = \"15\" (lower boundary of D5) must be accepted."
  }
}

# Scenario: "Validation Boundaries (accept)" - accepts_upper_boundaries
run "accepts_upper_boundaries" {
  command = plan

  variables {
    web = { name = join("", [for i in range(32) : "a"]) }
    app = {
      name              = join("", [for i in range(64) : "a"])
      port              = 65535
      health_check_path = format("/%s", join("", [for i in range(1023) : "a"]))
      user_data         = join("", [for i in range(16) : join("", [for j in range(1024) : "a"])])
      root_volume_size  = 16384
      min_size          = 2
      max_size          = 2
    }
    database = {
      name                    = join("", [for i in range(63) : "a"])
      allocated_storage       = 65536
      db_name                 = join("", [for i in range(63) : "a"])
      username                = join("", [for i in range(63) : "a"])
      port                    = 65535
      backup_retention_period = 35
    }
  }

  assert {
    condition     = length(aws_lb.web.name) == 32
    error_message = "A 32-character web.name (upper boundary of W1) must be accepted."
  }

  assert {
    condition     = aws_autoscaling_group.app.name == join("", [for i in range(64) : "a"])
    error_message = "A 64-character app.name (upper boundary of A1) must be accepted."
  }

  assert {
    condition     = length(aws_lb_target_group.app.health_check[0].path) == 1024
    error_message = "A 1024-character app.health_check_path (upper boundary of A6) must be accepted."
  }

  assert {
    condition     = length(base64decode(aws_launch_template.app.user_data)) == 16384
    error_message = "A 16384-character app.user_data (upper boundary of A12) must be accepted."
  }

  assert {
    condition     = aws_autoscaling_group.app.max_size == aws_autoscaling_group.app.min_size
    error_message = "app.max_size equal to app.min_size (boundary of A10) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].backup_retention_period == 35
    error_message = "database.backup_retention_period = 35 (upper boundary of D12) must be accepted."
  }

  assert {
    condition     = aws_db_instance.database[0].allocated_storage == 65536
    error_message = "database.allocated_storage = 65536 (upper boundary of D7) must be accepted."
  }

  assert {
    condition     = length(aws_db_instance.database[0].identifier) == 63
    error_message = "A 63-character database.name (upper boundary of D2) must be accepted."
  }
}

# Scenario: "Validation Boundaries (accept)" - accepts_alternate_formats
# The fixture's aws_ec2_instance_type mock returns ["x86_64"] for any type, so
# the arm instance type does not trip check.ami_architecture here.
run "accepts_alternate_formats" {
  command = plan

  variables {
    web = {
      name            = "Web-01"
      certificate_arn = "arn:aws-us-gov:acm:us-gov-west-1:123456789012:certificate/abc-123"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04"
    }
    app = {
      instance_type   = "m7g.16xlarge"
      ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/mrk-0123456789abcdef"
      managed_policy_arns = {
        custom = "arn:aws-us-gov:iam::123456789012:policy/path/app"
      }
    }
    ami = {
      owners       = ["self"]
      name_pattern = "*"
    }
    database = {
      name                           = "a1-b2"
      engine_version                 = "18"
      instance_class                 = "db.r7g.large"
      username                       = "Svc_Admin_1"
      kms_key_arn                    = "arn:aws:kms:eu-west-1:123456789012:key/mrk-0123456789abcdef"
      master_user_secret_kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/abc"
    }
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04"
    error_message = "A FIPS TLS 1.3 policy and a GovCloud certificate ARN must be accepted."
  }

  assert {
    condition     = aws_launch_template.app.instance_type == "m7g.16xlarge"
    error_message = "A multi-digit instance size (m7g.16xlarge) must be accepted by A3."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.app["custom"].policy_arn == "arn:aws-us-gov:iam::123456789012:policy/path/app"
    error_message = "A GovCloud customer-managed policy ARN with a path must be accepted by A14."
  }

  assert {
    condition     = aws_db_instance.database[0].identifier == "a1-b2"
    error_message = "A database.name with single hyphens and digits must be accepted by D3."
  }

  assert {
    condition     = aws_db_instance.database[0].engine_version == "18"
    error_message = "A newer major engine version (18) must be accepted."
  }
}

# Scenario: "Validation Boundaries (accept)" - accepts_each_allowed_ssl_policy
run "accepts_each_allowed_ssl_policy" {
  command = plan

  variables {
    web = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-3-2021-06"
    }
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-3-2021-06"
    error_message = "The TLS 1.3-only policy must be accepted by W5."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"
    error_message = "With a certificate, the HTTP listener must issue a permanent (HTTP_301) redirect."
  }
}

# --- Reject cases (validation errors) ---

# Scenario: "Validation Errors (reject)" - V1
run "reject_vpc_id_format" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc_123"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - V2
run "reject_public_subnets_single" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - V3
run "reject_public_subnet_id_format" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "sn-2" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - V4
run "reject_private_subnets_single" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - V5
run "reject_private_subnet_id_format" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "bad" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - V6
run "reject_database_subnet_id_format" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
      database_subnet_ids = { db-a = "bad", db-b = "subnet-0000000000000002b" }
    }
  }

  expect_failures = [var.vpc]
}

# Scenario: "Validation Errors (reject)" - W1
run "reject_web_name_too_long" {
  command = plan

  variables {
    web = { name = join("", [for i in range(33) : "a"]) }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - W2
run "reject_web_name_leading_hyphen" {
  command = plan

  variables {
    web = { name = "-web" }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - W3
run "reject_web_name_internal_prefix" {
  command = plan

  variables {
    web = { name = "internal-web" }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - W4
run "reject_web_certificate_arn_format" {
  command = plan

  variables {
    web = { certificate_arn = "arn:aws:iam::123456789012:server-certificate/x" }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - W5 (legacy policy)
run "reject_web_ssl_policy_legacy" {
  command = plan

  variables {
    web = { ssl_policy = "ELBSecurityPolicy-2016-08" }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - W5 (extended policy)
run "reject_web_ssl_policy_extended" {
  command = plan

  variables {
    web = { ssl_policy = "ELBSecurityPolicy-TLS13-1-2-Ext1-2021-06" }
  }

  expect_failures = [var.web]
}

# Scenario: "Validation Errors (reject)" - A1
run "reject_app_name_too_long" {
  command = plan

  variables {
    app = { name = join("", [for i in range(65) : "a"]) }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A2
run "reject_app_name_trailing_hyphen" {
  command = plan

  variables {
    app = { name = "app-" }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A3
run "reject_app_instance_type_format" {
  command = plan

  variables {
    app = { instance_type = "t3micro" }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A4 (zero)
run "reject_app_port_zero" {
  command = plan

  variables {
    app = { port = 0 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A4 (above max)
run "reject_app_port_above_max" {
  command = plan

  variables {
    app = { port = 65536 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A5
run "reject_app_health_check_path_relative" {
  command = plan

  variables {
    app = { health_check_path = "health" }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A6
run "reject_app_health_check_path_too_long" {
  command = plan

  variables {
    app = { health_check_path = format("/%s", join("", [for i in range(1024) : "a"])) }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A7
run "reject_app_grace_period_negative" {
  command = plan

  variables {
    app = { health_check_grace_period = -1 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A8
run "reject_app_min_size_negative" {
  command = plan

  variables {
    app = { min_size = -1, max_size = 1 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A9
run "reject_app_max_size_zero" {
  command = plan

  variables {
    app = { min_size = 0, max_size = 0 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A10
run "reject_app_max_below_min" {
  command = plan

  variables {
    app = { min_size = 3, max_size = 2 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A11 (too small)
run "reject_app_root_volume_too_small" {
  command = plan

  variables {
    app = { root_volume_size = 7 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A11 (too large)
run "reject_app_root_volume_too_large" {
  command = plan

  variables {
    app = { root_volume_size = 16385 }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A12
run "reject_app_user_data_too_long" {
  command = plan

  variables {
    app = { user_data = format("%sb", join("", [for i in range(16) : join("", [for j in range(1024) : "a"])])) }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A13
run "reject_app_ebs_kms_alias" {
  command = plan

  variables {
    app = { ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/ebs" }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - A14
run "reject_app_policy_not_arn" {
  command = plan

  variables {
    app = { managed_policy_arns = { ssm = "AmazonSSMManagedInstanceCore" } }
  }

  expect_failures = [var.app]
}

# Scenario: "Validation Errors (reject)" - M1
run "reject_ami_owners_empty" {
  command = plan

  variables {
    ami = { owners = [] }
  }

  expect_failures = [var.ami]
}

# Scenario: "Validation Errors (reject)" - M2
run "reject_ami_name_pattern_empty" {
  command = plan

  variables {
    ami = { name_pattern = "" }
  }

  expect_failures = [var.ami]
}

# Scenario: "Validation Errors (reject)" - D1 (cross-variable)
run "reject_database_without_database_subnets" {
  command = plan

  variables {
    vpc = {
      vpc_id              = "vpc-0123456789abcdef0"
      public_subnet_ids   = { web-a = "subnet-0000000000000000a", web-b = "subnet-0000000000000000b" }
      private_subnet_ids  = { app-a = "subnet-0000000000000001a", app-b = "subnet-0000000000000001b" }
      database_subnet_ids = { db-a = "subnet-0000000000000002a" }
    }
    database = {}
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D2
run "reject_database_name_too_long" {
  command = plan

  variables {
    database = { name = join("", [for i in range(64) : "a"]) }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D3 (double hyphen)
run "reject_database_name_double_hyphen" {
  command = plan

  variables {
    database = { name = "a--b" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D3 (leading digit)
run "reject_database_name_leading_digit" {
  command = plan

  variables {
    database = { name = "1db" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D4
run "reject_database_engine_version_minor" {
  command = plan

  variables {
    database = { engine_version = "16.4" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D5
run "reject_database_engine_version_below_15" {
  command = plan

  variables {
    database = { engine_version = "14" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D6
run "reject_database_instance_class_prefix" {
  command = plan

  variables {
    database = { instance_class = "t4g.micro" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D7 (too small)
run "reject_database_storage_too_small" {
  command = plan

  variables {
    database = { allocated_storage = 19 }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D7 (too large)
run "reject_database_storage_too_large" {
  command = plan

  variables {
    database = { allocated_storage = 65537 }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D8
run "reject_database_db_name_format" {
  command = plan

  variables {
    database = { db_name = "1app" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D9
run "reject_database_username_format" {
  command = plan

  variables {
    database = { username = "app-admin" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D10 (reserved)
run "reject_database_username_reserved" {
  command = plan

  variables {
    database = { username = "postgres" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D10 (reserved, mixed case)
run "reject_database_username_reserved_case" {
  command = plan

  variables {
    database = { username = "Admin" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D11
run "reject_database_port_below_min" {
  command = plan

  variables {
    database = { port = 1149 }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D12 (zero)
run "reject_database_backup_zero" {
  command = plan

  variables {
    database = { backup_retention_period = 0 }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D12 (above max)
run "reject_database_backup_above_max" {
  command = plan

  variables {
    database = { backup_retention_period = 36 }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D13
run "reject_database_kms_alias" {
  command = plan

  variables {
    database = { kms_key_arn = "alias/aws/rds" }
  }

  expect_failures = [var.database]
}

# Scenario: "Validation Errors (reject)" - D14
run "reject_database_secret_kms_alias" {
  command = plan

  variables {
    database = { master_user_secret_kms_key_arn = "alias/secrets" }
  }

  expect_failures = [var.database]
}

# Generated from specs/003-three-tier-app/design.md Section 5
# Scenario: "Secure Defaults (basic)" - the module plans with only `vpc`, and
# every security control is on by default. Unit test: mock provider, plan only.

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

# Scenario: "Secure Defaults (basic)" - web_tier_defaults
run "web_tier_defaults" {
  command = plan

  assert {
    condition     = aws_lb.web.internal == false
    error_message = "The ALB must be internet-facing (internal = false) because it is the public web tier."
  }

  assert {
    condition     = aws_lb.web.load_balancer_type == "application"
    error_message = "The web tier load balancer must be an application load balancer."
  }

  assert {
    condition     = aws_lb.web.name == "three-tier-app-web"
    error_message = "The ALB name must default to web.name (three-tier-app-web)."
  }

  assert {
    condition     = aws_lb.web.subnets == toset(["subnet-0000000000000000a", "subnet-0000000000000000b"])
    error_message = "The ALB must be placed only in the public subnets from vpc.public_subnet_ids."
  }

  assert {
    condition     = contains(aws_lb.web.security_groups, "sg-0000000000000web0")
    error_message = "The ALB must use the web security group."
  }

  assert {
    condition     = length(aws_lb.web.access_logs) == 0
    error_message = "ALB access logs must not be configured (user-directed, see design OQ-2)."
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "No HTTPS listener may be created when web.certificate_arn is null."
  }

  assert {
    condition     = aws_lb_listener.http.port == 80
    error_message = "The HTTP listener must listen on port 80."
  }

  assert {
    condition     = aws_lb_listener.http.protocol == "HTTP"
    error_message = "The port-80 listener must use the HTTP protocol."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "Without a certificate, the HTTP listener default action must be forward."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].target_group_arn == aws_lb_target_group.app.arn
    error_message = "Without a certificate, the HTTP listener must forward to the app target group."
  }

  assert {
    condition     = length(aws_lb_listener.http.default_action[0].redirect) == 0
    error_message = "Without a certificate, the HTTP listener must not contain a redirect block."
  }

  assert {
    condition     = aws_lb_target_group.app.port == 8080
    error_message = "The target group port must default to app.port (8080)."
  }

  assert {
    condition     = aws_lb_target_group.app.protocol == "HTTP"
    error_message = "The target group must use HTTP (TLS terminates at the ALB)."
  }

  assert {
    condition     = aws_lb_target_group.app.health_check[0].path == "/"
    error_message = "The target group health check path must default to app.health_check_path (/)."
  }

  assert {
    condition     = aws_lb_target_group.app.name_prefix == "three-"
    error_message = "The target group name_prefix must be the first 6 characters of app.name (three-)."
  }

  assert {
    condition     = aws_lb_target_group.app.vpc_id == "vpc-0123456789abcdef0"
    error_message = "The target group must be created in vpc.vpc_id."
  }
}

# Scenario: "Secure Defaults (basic)" - app_tier_defaults
run "app_tier_defaults" {
  command = plan

  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_tokens == "required"
    error_message = "The launch template must require IMDSv2 (http_tokens = required)."
  }

  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_endpoint == "enabled"
    error_message = "The launch template must enable the instance metadata endpoint."
  }

  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The IMDS hop limit must be 1 so containers cannot reach instance credentials."
  }

  # ebs.encrypted is string-typed in provider 5.x
  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "The root volume must be encrypted (ebs.encrypted = \"true\")."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].kms_key_id == null
    error_message = "Without app.ebs_kms_key_arn, the root volume must use the AWS-managed key (kms_key_id = null)."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "The root volume must be gp3."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 20
    error_message = "The root volume size must default to app.root_volume_size (20 GiB)."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].device_name == "/dev/xvda"
    error_message = "The root block device mapping must use the AMI's root_device_name (/dev/xvda)."
  }

  # network_interfaces.associate_public_ip_address is string-typed in provider 5.x
  assert {
    condition     = aws_launch_template.app.network_interfaces[0].associate_public_ip_address == "false"
    error_message = "App servers must not receive public IPs (associate_public_ip_address = \"false\")."
  }

  assert {
    condition     = contains(aws_launch_template.app.network_interfaces[0].security_groups, "sg-0000000000000app0")
    error_message = "The launch template ENI must carry the app security group."
  }

  assert {
    condition     = aws_launch_template.app.iam_instance_profile[0].arn == "arn:aws:iam::123456789012:instance-profile/three-tier-app"
    error_message = "The launch template must attach the app instance profile."
  }

  assert {
    condition     = aws_launch_template.app.image_id == "ami-0123456789abcdef0"
    error_message = "The launch template image must come from data.aws_ami.selected."
  }

  assert {
    condition     = aws_launch_template.app.instance_type == "t3.micro"
    error_message = "The instance type must default to app.instance_type (t3.micro)."
  }

  assert {
    condition     = aws_launch_template.app.user_data == null
    error_message = "The launch template must have no user data when app.user_data is null."
  }

  assert {
    condition     = aws_autoscaling_group.app.health_check_type == "ELB"
    error_message = "The ASG must use ELB health checks so failing servers are replaced."
  }

  assert {
    condition     = aws_autoscaling_group.app.health_check_grace_period == 300
    error_message = "The ASG health check grace period must default to 300 seconds."
  }

  assert {
    condition     = aws_autoscaling_group.app.min_size == 2
    error_message = "The ASG min_size must default to 2."
  }

  assert {
    condition     = aws_autoscaling_group.app.max_size == 4
    error_message = "The ASG max_size must default to 4."
  }

  assert {
    condition     = aws_autoscaling_group.app.vpc_zone_identifier == toset(["subnet-0000000000000001a", "subnet-0000000000000001b"])
    error_message = "The ASG must be placed only in the private subnets from vpc.private_subnet_ids."
  }

  assert {
    condition     = contains(aws_autoscaling_group.app.target_group_arns, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/0123456789abcdef")
    error_message = "The ASG must register its instances in the app target group."
  }

  assert {
    condition     = aws_autoscaling_group.app.instance_refresh[0].strategy == "Rolling"
    error_message = "The ASG must use a Rolling instance refresh so template changes roll through the fleet."
  }

  assert {
    condition     = aws_autoscaling_group.app.instance_refresh[0].preferences[0].min_healthy_percentage == 90
    error_message = "The ASG instance refresh must keep at least 90% of the fleet healthy."
  }

  # [plan-unknown] "ASG follows the latest LT version"
  # (launch_template[0].version == tostring(aws_launch_template.app.latest_version))
  # is unknown at plan and is asserted in the integration test instead.
}

# Scenario: "Secure Defaults (basic)" - iam_defaults
run "iam_defaults" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.app.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"
    error_message = "The app role must trust only ec2.amazonaws.com."
  }

  assert {
    condition     = jsondecode(aws_iam_role.app.assume_role_policy).Statement[0].Action == "sts:AssumeRole"
    error_message = "The app role trust policy must allow only sts:AssumeRole."
  }

  assert {
    condition     = aws_iam_role.app.name == "three-tier-app"
    error_message = "The app role name must default to app.name (three-tier-app)."
  }

  assert {
    condition     = aws_iam_instance_profile.app.role == "three-tier-app"
    error_message = "The instance profile must wrap the app role."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.app) == 1
    error_message = "Exactly one managed policy must be attached by default."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.app["ssm"].policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The default policy attachment must be AmazonSSMManagedInstanceCore only (Session Manager, no SSH)."
  }
}

# Scenario: "Secure Defaults (basic)" - network_defaults
run "network_defaults" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_http.security_group_id == "sg-0000000000000web0"
    error_message = "The HTTP ingress rule must be on the web security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_http.cidr_ipv4 == "0.0.0.0/0"
    error_message = "The web HTTP ingress rule must allow the internet (0.0.0.0/0)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_http.from_port == 80
    error_message = "The web HTTP ingress rule must be on port 80."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.web_https) == 0
    error_message = "No 443 ingress rule may exist without a certificate."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.web_to_app.referenced_security_group_id == "sg-0000000000000app0"
    error_message = "Web egress must target only the app security group."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.web_to_app.from_port == 8080
    error_message = "Web egress must be on app.port (8080)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_from_web.referenced_security_group_id == "sg-0000000000000web0"
    error_message = "App ingress must come only from the web security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_from_web.cidr_ipv4 == null
    error_message = "App ingress must not use a CIDR source."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_from_web.to_port == 8080
    error_message = "App ingress must be on app.port (8080)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "App HTTPS egress must target 0.0.0.0/0 (cloud APIs and package repositories)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https.from_port == 443
    error_message = "App HTTPS egress must be on port 443."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https.ip_protocol == "tcp"
    error_message = "App HTTPS egress must be TCP only."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.app_to_database) == 0
    error_message = "No app-to-database egress rule may exist without a data tier."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.database_from_app) == 0
    error_message = "No database ingress rule may exist without a data tier."
  }
}

# Scenario: "Secure Defaults (basic)" - data_tier_absent
run "data_tier_absent" {
  command = plan

  assert {
    condition     = length(aws_db_instance.database) == 0
    error_message = "No DB instance may be created when database is null."
  }

  assert {
    condition     = length(aws_db_subnet_group.database) == 0
    error_message = "No DB subnet group may be created when database is null."
  }

  assert {
    condition     = length(aws_security_group.database) == 0
    error_message = "No database security group may be created when database is null."
  }

  assert {
    condition     = output.db_instance_endpoint == null
    error_message = "The db_instance_endpoint output must be null without a data tier."
  }

  assert {
    condition     = output.db_instance_master_user_secret_arn == null
    error_message = "The db_instance_master_user_secret_arn output must be null without a data tier."
  }

  assert {
    condition     = output.database_security_group_id == null
    error_message = "The database_security_group_id output must be null without a data tier."
  }

  assert {
    condition     = output.https_listener_arn == null
    error_message = "The https_listener_arn output must be null without a certificate."
  }
}

# Scenario: "Secure Defaults (basic)" - tags_and_outputs
run "tags_and_outputs" {
  command = plan

  assert {
    condition     = aws_lb.web.tags["Name"] == "three-tier-app-web"
    error_message = "The ALB Name tag must be web.name (three-tier-app-web)."
  }

  assert {
    condition     = aws_security_group.app.tags["Name"] == "three-tier-app"
    error_message = "The app security group Name tag must be app.name (three-tier-app)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_https.tags["Name"] == "three-tier-app"
    error_message = "Security group rules must carry the owning subsystem's Name tag (three-tier-app)."
  }

  assert {
    condition     = aws_launch_template.app.tag_specifications[0].resource_type == "volume"
    error_message = "The launch template must tag volumes via tag_specifications (ASG tags never reach volumes)."
  }

  assert {
    condition     = aws_launch_template.app.tag_specifications[0].tags["Name"] == "three-tier-app"
    error_message = "Volumes must receive the app Name tag (three-tier-app)."
  }

  # aws_autoscaling_group.tag is a set: filter with for and one(), never [0]
  assert {
    condition     = one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Name"]) == "three-tier-app"
    error_message = "The ASG must emit a Name tag of app.name (three-tier-app) for instances."
  }

  assert {
    condition     = one([for t in aws_autoscaling_group.app.tag : t.propagate_at_launch if t.key == "Name"]) == true
    error_message = "The ASG Name tag must propagate to instances at launch."
  }

  assert {
    condition     = output.ami_id == "ami-0123456789abcdef0"
    error_message = "The ami_id output must be the selected AMI ID."
  }

  assert {
    condition     = output.autoscaling_group_name == "three-tier-app"
    error_message = "The autoscaling_group_name output must be app.name (three-tier-app)."
  }

  assert {
    condition     = output.iam_role_name == "three-tier-app"
    error_message = "The iam_role_name output must be app.name (three-tier-app)."
  }

  # [plan-unknown] "DNS output" (output.alb_dns_name) is unknown at plan and is
  # asserted in the integration test instead.
}

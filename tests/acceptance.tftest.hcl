# Acceptance tests: real AWS provider, plan only.
#
# Run in CI or a sandbox account with credentials, TF_VAR_region and TF_VAR_vpc
# (real VPC and subnet IDs) set. Not run as part of the unit test suite:
#   terraform test -filter=tests/acceptance.tftest.hcl

provider "aws" {
  region = var.region
}

variables {
  database = {
    deletion_protection = false
    skip_final_snapshot = true
  }
}

# Scenario: "Plan Verification" - plan_resolves_real_data
# acceptance
run "plan_resolves_real_data" {
  command = plan

  assert {
    condition     = can(regex("^ami-[0-9a-f]+$", data.aws_ami.selected.id))
    error_message = "The AMI data source must resolve to a real AMI ID."
  }

  assert {
    condition     = data.aws_ami.selected.architecture == "x86_64"
    error_message = "The resolved AMI architecture must match the default instance type (x86_64)."
  }

  assert {
    condition     = aws_launch_template.app.image_id == data.aws_ami.selected.id
    error_message = "The launch template must use the resolved AMI."
  }

  assert {
    condition     = aws_launch_template.app.block_device_mappings[0].device_name == data.aws_ami.selected.root_device_name
    error_message = "The launch template root device must match the real AMI's root_device_name."
  }

  assert {
    condition     = output.ami_id == data.aws_ami.selected.id
    error_message = "The ami_id output must be the resolved AMI ID."
  }

  assert {
    condition     = length(aws_db_subnet_group.database[0].subnet_ids) >= 2
    error_message = "The DB subnet group must plan against at least two real database subnets."
  }
}

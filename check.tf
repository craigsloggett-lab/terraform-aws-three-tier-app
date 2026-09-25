check "subnets_in_vpc" {
  data "aws_subnets" "in_vpc" {
    filter {
      name   = "vpc-id"
      values = [var.vpc.vpc_id]
    }
  }

  assert {
    condition     = alltrue([for id in local.check_subnet_ids : contains(data.aws_subnets.in_vpc.ids, id)])
    error_message = "Every subnet in vpc.public_subnet_ids, vpc.private_subnet_ids and vpc.database_subnet_ids must belong to vpc.vpc_id (${var.vpc.vpc_id})."
  }
}

check "ami_architecture" {
  data "aws_ec2_instance_type" "app" {
    instance_type = var.app.instance_type
  }

  assert {
    condition     = contains(data.aws_ec2_instance_type.app.supported_architectures, data.aws_ami.selected.architecture)
    error_message = "The selected AMI architecture (${data.aws_ami.selected.architecture}) is not supported by app.instance_type (${var.app.instance_type}). Adjust ami.name_pattern or app.instance_type."
  }
}

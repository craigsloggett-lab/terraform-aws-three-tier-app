# terraform-aws-three-tier-app

A Terraform module to deploy the infrastructure for a three-tier application on AWS.

<!-- BEGIN_TF_DOCS -->
## Usage

### main.tf
```hcl
# tflint-ignore: terraform_required_version
module "three_tier_app" {
  source  = "app.terraform.io/craigsloggett-lab/three-tier-app/aws"
  version = "0.0.1"
}
```

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.14 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

No providers.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ami"></a> [ami](#input\_ami) | App server image selection. The most recent match wins.<br/><br/>- `owners`: AMI owner account IDs or aliases (`amazon`, `self`). It is always set, so image lookups are never unscoped.<br/>- `name_pattern`: AMI name filter (wildcards allowed). A newer matching image rolls the fleet on the next apply. | <pre>object({<br/>    owners       = optional(list(string), ["amazon"])<br/>    name_pattern = optional(string, "al2023-ami-2023.*-x86_64")<br/>  })</pre> | `{}` | no |
| <a name="input_app"></a> [app](#input\_app) | App tier (server fleet) settings.<br/><br/>- `name`: Name for the ASG, IAM role and instance profile. It prefixes the launch template, security group and target group, and is the `Name` tag for app-tier resources.<br/>- `instance_type`: EC2 instance type. Its architecture must match the selected AMI (checked in `check.tf`).<br/>- `port`: Port the application listens on. It is the only port the load balancer can reach.<br/>- `health_check_path`: HTTP path the load balancer probes. Servers that fail it are replaced.<br/>- `health_check_grace_period`: Seconds after launch before failed health checks count. Size it to cover boot plus user data.<br/>- `min_size`: Minimum fleet size.<br/>- `max_size`: Maximum fleet size.<br/>- `root_volume_size`: Root EBS volume size in GiB (gp3, always encrypted).<br/>- `user_data`: Plain-text boot script. The module base64-encodes it. Do not embed secrets, because anyone with instance metadata or DescribeInstanceAttribute access can read user data.<br/>- `ebs_kms_key_arn`: Customer-managed KMS key ARN for the root volume. When null, the AWS-managed `aws/ebs` key is used. The key policy MUST let the `AWSServiceRoleForAutoScaling` service-linked role use the key (`kms:CreateGrant`, `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`). Otherwise instances terminate at launch with `Client.InvalidKMSKey.InvalidState`.<br/>- `managed_policy_arns`: Managed IAM policies attached to the instance role, keyed by a static name you choose. The default grants Session Manager only, with no SSH. Setting this map replaces the default, so keep `ssm` if you need it. To read the database secret, add a policy granting `secretsmanager:GetSecretValue` on `db_instance_master_user_secret_arn`, plus `kms:Decrypt` if you use a secret CMK. Callers outside the `aws` partition must override the default ARN. | <pre>object({<br/>    name                      = optional(string, "three-tier-app")<br/>    instance_type             = optional(string, "t3.micro")<br/>    port                      = optional(number, 8080)<br/>    health_check_path         = optional(string, "/")<br/>    health_check_grace_period = optional(number, 300)<br/>    min_size                  = optional(number, 2)<br/>    max_size                  = optional(number, 4)<br/>    root_volume_size          = optional(number, 20)<br/>    user_data                 = optional(string)<br/>    ebs_kms_key_arn           = optional(string)<br/>    managed_policy_arns = optional(map(string), {<br/>      ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"<br/>    })<br/>  })</pre> | `{}` | no |
| <a name="input_database"></a> [database](#input\_database) | Data tier settings. When null, no data tier is created. When set (even `{}`), a single encrypted PostgreSQL instance is created in the database subnets.<br/><br/>- `name`: DB identifier, subnet group name, security group prefix and `Name` tag. The final snapshot is `<name>-final`.<br/>- `engine_version`: PostgreSQL **major** version, 15 or later. Minor versions upgrade automatically, and 15+ enforces TLS by default.<br/>- `instance_class`: RDS instance class.<br/>- `allocated_storage`: Storage in GiB (gp3, always encrypted).<br/>- `db_name`: Name of the initial database.<br/>- `username`: Master username. RDS generates the password and stores it in Secrets Manager.<br/>- `port`: Database port. Only the app tier can reach it.<br/>- `multi_az`: Keep a synchronous standby in a second AZ.<br/>- `backup_retention_period`: Days of automated backups. Backups cannot be disabled.<br/>- `deletion_protection`: Block deletion of the database. To destroy, set it to false and apply first.<br/>- `skip_final_snapshot`: Skip the `<name>-final` snapshot on destroy. Set it to true only for disposable environments.<br/>- `kms_key_arn`: Customer-managed KMS key ARN for storage encryption. When null, `aws/rds` is used. Changing it replaces the database.<br/>- `master_user_secret_kms_key_arn`: Customer-managed KMS key ARN for the master-password secret. When null, `aws/secretsmanager` is used. | <pre>object({<br/>    name                           = optional(string, "three-tier-app-db")<br/>    engine_version                 = optional(string, "16")<br/>    instance_class                 = optional(string, "db.t4g.micro")<br/>    allocated_storage              = optional(number, 20)<br/>    db_name                        = optional(string, "app")<br/>    username                       = optional(string, "app_admin")<br/>    port                           = optional(number, 5432)<br/>    multi_az                       = optional(bool, true)<br/>    backup_retention_period        = optional(number, 7)<br/>    deletion_protection            = optional(bool, true)<br/>    skip_final_snapshot            = optional(bool, false)<br/>    kms_key_arn                    = optional(string)<br/>    master_user_secret_kms_key_arn = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource beneath the module's `Name` tag. A `Name` key here is ignored. | `map(string)` | `{}` | no |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | The existing network to deploy into. Pass the `craigsloggett-lab/vpc/aws` outputs directly. The module never creates networking.<br/><br/>- `vpc_id`: ID of the existing VPC.<br/>- `public_subnet_ids`: Public subnets for the load balancer, keyed by subnet name. They must be in at least two AZs.<br/>- `private_subnet_ids`: Private subnets for the app fleet, keyed by subnet name. They should be in at least two AZs.<br/>- `database_subnet_ids`: Database subnets, keyed by subnet name. Required (2 or more) only when `database` is set. | <pre>object({<br/>    vpc_id              = string<br/>    public_subnet_ids   = map(string)<br/>    private_subnet_ids  = map(string)<br/>    database_subnet_ids = optional(map(string), {})<br/>  })</pre> | n/a | yes |
| <a name="input_web"></a> [web](#input\_web) | Web tier (internet-facing load balancer) settings.<br/><br/>- `name`: Load balancer name and `Name` tag for web-tier resources. It must be unique per account and region.<br/>- `certificate_arn`: ACM certificate ARN. When set, the module serves HTTPS on 443 and redirects HTTP to it. When null, it serves HTTP only on 80.<br/>- `ssl_policy`: TLS policy for the HTTPS listener. Only TLS 1.2+ policies are allowed. | <pre>object({<br/>    name            = optional(string, "three-tier-app-web")<br/>    certificate_arn = optional(string)<br/>    ssl_policy      = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")<br/>  })</pre> | `{}` | no |

## Resources

No resources.

## Outputs

No outputs.
<!-- END_TF_DOCS -->

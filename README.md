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

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |

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

| Name | Type |
| ---- | ---- |
| [aws_autoscaling_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_db_instance.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_instance_profile.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_launch_template.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_lb.web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.http](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_listener.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_security_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.app_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.app_to_database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.web_to_app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.app_from_web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.database_from_app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.web_http](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.web_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_ami.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_arn"></a> [alb\_arn](#output\_alb\_arn) | ARN of the load balancer. |
| <a name="output_alb_arn_suffix"></a> [alb\_arn\_suffix](#output\_alb\_arn\_suffix) | ARN suffix of the load balancer, for CloudWatch metric dimensions. |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the load balancer. Point a CNAME or alias record at it. |
| <a name="output_alb_zone_id"></a> [alb\_zone\_id](#output\_alb\_zone\_id) | Hosted zone ID of the load balancer, for Route 53 alias records. |
| <a name="output_ami_id"></a> [ami\_id](#output\_ami\_id) | ID of the AMI the launch template currently uses. |
| <a name="output_app_security_group_id"></a> [app\_security\_group\_id](#output\_app\_security\_group\_id) | ID of the app server security group. Reference it to allow app access to other services. |
| <a name="output_autoscaling_group_arn"></a> [autoscaling\_group\_arn](#output\_autoscaling\_group\_arn) | ARN of the ASG. |
| <a name="output_autoscaling_group_name"></a> [autoscaling\_group\_name](#output\_autoscaling\_group\_name) | Name of the ASG. Attach scaling policies to it. |
| <a name="output_database_security_group_id"></a> [database\_security\_group\_id](#output\_database\_security\_group\_id) | ID of the database security group. Null without a data tier. |
| <a name="output_db_instance_address"></a> [db\_instance\_address](#output\_db\_instance\_address) | Database hostname. Null without a data tier. |
| <a name="output_db_instance_arn"></a> [db\_instance\_arn](#output\_db\_instance\_arn) | RDS instance ARN. Null without a data tier. |
| <a name="output_db_instance_endpoint"></a> [db\_instance\_endpoint](#output\_db\_instance\_endpoint) | Database host:port. Null without a data tier. |
| <a name="output_db_instance_identifier"></a> [db\_instance\_identifier](#output\_db\_instance\_identifier) | RDS instance identifier. Null without a data tier. |
| <a name="output_db_instance_master_user_secret_arn"></a> [db\_instance\_master\_user\_secret\_arn](#output\_db\_instance\_master\_user\_secret\_arn) | ARN of the Secrets Manager secret holding the master credentials. Grant secretsmanager:GetSecretValue on it (and kms:Decrypt on its key) to readers. Null without a data tier. |
| <a name="output_db_instance_port"></a> [db\_instance\_port](#output\_db\_instance\_port) | Database port. Null without a data tier. |
| <a name="output_db_subnet_group_name"></a> [db\_subnet\_group\_name](#output\_db\_subnet\_group\_name) | Name of the DB subnet group. Null without a data tier. |
| <a name="output_http_listener_arn"></a> [http\_listener\_arn](#output\_http\_listener\_arn) | ARN of the port-80 listener (redirects when HTTPS is enabled, forwards otherwise). |
| <a name="output_https_listener_arn"></a> [https\_listener\_arn](#output\_https\_listener\_arn) | ARN of the port-443 listener. Attach extra certificates or rules to it. Null without a certificate. |
| <a name="output_iam_instance_profile_arn"></a> [iam\_instance\_profile\_arn](#output\_iam\_instance\_profile\_arn) | ARN of the instance profile. |
| <a name="output_iam_role_arn"></a> [iam\_role\_arn](#output\_iam\_role\_arn) | ARN of the instance role. |
| <a name="output_iam_role_name"></a> [iam\_role\_name](#output\_iam\_role\_name) | Name of the instance role. Attach extra policies to it. |
| <a name="output_launch_template_id"></a> [launch\_template\_id](#output\_launch\_template\_id) | ID of the launch template. |
| <a name="output_launch_template_latest_version"></a> [launch\_template\_latest\_version](#output\_launch\_template\_latest\_version) | Latest launch template version, which is the version the ASG runs. |
| <a name="output_target_group_arn"></a> [target\_group\_arn](#output\_target\_group\_arn) | ARN of the app target group. |
| <a name="output_target_group_arn_suffix"></a> [target\_group\_arn\_suffix](#output\_target\_group\_arn\_suffix) | ARN suffix of the target group, for CloudWatch metric dimensions. |
| <a name="output_web_security_group_id"></a> [web\_security\_group\_id](#output\_web\_security\_group\_id) | ID of the load balancer security group. |
<!-- END_TF_DOCS -->

# Example - Public HTTPS

A runnable, self-contained deployment of the three-tier app. It creates a VPC with the org `vpc` module (public, private and database subnets in two AZs, one NAT gateway), then deploys:

- An internet-facing load balancer that serves HTTPS on 443 with your ACM certificate and redirects HTTP on port 80 to it.
- An app fleet of 1-2 instances in the private subnets that serves a static page on port 8080.
- A single-AZ PostgreSQL instance in the database subnets, with the master password in Secrets Manager.

The database uses disposable settings (`deletion_protection = false`, `skip_final_snapshot = true`, one day of backups) so `terraform destroy` removes everything. Keep the module defaults in production.

## Prerequisites

- An issued ACM certificate in the target region.
- A token for `app.terraform.io` (for example `TF_TOKEN_app_terraform_io`) so Terraform can download the private `vpc` module.

## Running

```sh
cp defaults.auto.tfvars.example defaults.auto.tfvars # then edit the values
terraform init
terraform apply
```

Point a DNS record for the certificate's domain at the `alb_dns_name` output.

<!-- BEGIN_TF_DOCS -->
## Usage

### main.tf
```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "app.terraform.io/craigsloggett-lab/vpc/aws"
  version = "0.1.0"

  name               = "tta-public-https"
  cidr_block         = "10.0.0.0/16"
  single_nat_gateway = true

  public_subnets = {
    web-a = { cidr_block = "10.0.0.0/24", availability_zone = data.aws_availability_zones.available.names[0] }
    web-b = { cidr_block = "10.0.1.0/24", availability_zone = data.aws_availability_zones.available.names[1] }
  }

  private_subnets = {
    app-a = { cidr_block = "10.0.10.0/24", availability_zone = data.aws_availability_zones.available.names[0] }
    app-b = { cidr_block = "10.0.11.0/24", availability_zone = data.aws_availability_zones.available.names[1] }
  }

  database_subnets = {
    db-a = { cidr_block = "10.0.20.0/24", availability_zone = data.aws_availability_zones.available.names[0] }
    db-b = { cidr_block = "10.0.21.0/24", availability_zone = data.aws_availability_zones.available.names[1] }
  }
}

module "three_tier_app" {
  source = "../../"

  vpc = {
    vpc_id              = module.vpc.vpc_id
    public_subnet_ids   = module.vpc.public_subnet_ids
    private_subnet_ids  = module.vpc.private_subnet_ids
    database_subnet_ids = module.vpc.database_subnet_ids
  }

  web = {
    name            = "tta-public-https-web"
    certificate_arn = var.certificate_arn
  }

  app = {
    name     = "tta-public-https-app"
    min_size = 1
    max_size = 2

    # Serve a static page on the app port so the target group health check passes.
    user_data = <<-EOT
      #!/bin/bash
      set -euo pipefail
      mkdir -p /srv/www
      echo "three-tier-app public-https example" > /srv/www/index.html
      cat > /etc/systemd/system/app.service <<'UNIT'
      [Unit]
      Description=Example static web server
      After=network-online.target

      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --directory /srv/www
      Restart=always
      DynamicUser=yes

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now app.service
    EOT
  }

  # Disposable settings so the example destroys cleanly. Keep the defaults in production.
  database = {
    name                    = "tta-public-https-db"
    multi_az                = false
    backup_retention_period = 1
    deletion_protection     = false
    skip_final_snapshot     = true
  }
}
```

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.14 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 5.100.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_three_tier_app"></a> [three\_tier\_app](#module\_three\_tier\_app) | ../../ | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | app.terraform.io/craigsloggett-lab/vpc/aws | 0.1.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ARN of an issued ACM certificate in `region` for the load balancer's HTTPS listener. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy into, for example `us-east-1`. It must have at least two availability zones. | `string` | n/a | yes |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/availability_zones) | data source |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the load balancer. Point a CNAME or alias record for the certificate's domain at it. |
| <a name="output_db_instance_master_user_secret_arn"></a> [db\_instance\_master\_user\_secret\_arn](#output\_db\_instance\_master\_user\_secret\_arn) | ARN of the Secrets Manager secret holding the database master credentials. |
<!-- END_TF_DOCS -->

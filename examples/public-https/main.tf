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
    name                = "tta-public-https-db"
    multi_az            = false
    deletion_protection = false
    skip_final_snapshot = true
  }
}

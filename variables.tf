# Required

variable "vpc" {
  description = <<-EOT
    The existing network to deploy into. Pass the `craigsloggett-lab/vpc/aws` outputs directly. The module never creates networking.

    - `vpc_id`: ID of the existing VPC.
    - `public_subnet_ids`: Public subnets for the load balancer, keyed by subnet name. They must be in at least two AZs.
    - `private_subnet_ids`: Private subnets for the app fleet, keyed by subnet name. They should be in at least two AZs.
    - `database_subnet_ids`: Database subnets, keyed by subnet name. Required (2 or more) only when `database` is set.
  EOT
  type = object({
    vpc_id              = string
    public_subnet_ids   = map(string)
    private_subnet_ids  = map(string)
    database_subnet_ids = optional(map(string), {})
  })

  # V1
  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc.vpc_id))
    error_message = "vpc.vpc_id must be a VPC ID matching ^vpc-[0-9a-f]+$."
  }

  # V2
  validation {
    condition     = length(var.vpc.public_subnet_ids) >= 2
    error_message = "vpc.public_subnet_ids must contain at least 2 subnets (the load balancer spans at least two AZs)."
  }

  # V3
  validation {
    condition     = alltrue([for id in values(var.vpc.public_subnet_ids) : startswith(id, "subnet-")])
    error_message = "vpc.public_subnet_ids values must all be subnet IDs starting with \"subnet-\"."
  }

  # V4
  validation {
    condition     = length(var.vpc.private_subnet_ids) >= 2
    error_message = "vpc.private_subnet_ids must contain at least 2 subnets (the app fleet spans at least two AZs)."
  }

  # V5
  validation {
    condition     = alltrue([for id in values(var.vpc.private_subnet_ids) : startswith(id, "subnet-")])
    error_message = "vpc.private_subnet_ids values must all be subnet IDs starting with \"subnet-\"."
  }

  # V6
  validation {
    condition     = alltrue([for id in values(var.vpc.database_subnet_ids) : startswith(id, "subnet-")])
    error_message = "vpc.database_subnet_ids values must all be subnet IDs starting with \"subnet-\"."
  }
}

# Optional

variable "web" {
  description = <<-EOT
    Web tier (internet-facing load balancer) settings.

    - `name`: Load balancer name and `Name` tag for web-tier resources. It must be unique per account and region.
    - `certificate_arn`: ACM certificate ARN. When set, the module serves HTTPS on 443 and redirects HTTP to it. When null, it serves HTTP only on 80.
    - `ssl_policy`: TLS policy for the HTTPS listener. Only TLS 1.2+ policies are allowed.
  EOT
  type = object({
    name            = optional(string, "three-tier-app-web")
    certificate_arn = optional(string)
    ssl_policy      = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")
  })
  default = {}

  # W1
  validation {
    condition     = length(var.web.name) <= 32
    error_message = "web.name must be at most 32 characters."
  }

  # W2
  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.web.name))
    error_message = "web.name must contain only alphanumerics and hyphens, and must not start or end with a hyphen."
  }

  # W3
  validation {
    condition     = !startswith(var.web.name, "internal-")
    error_message = "web.name must not start with \"internal-\"."
  }

  # W4
  validation {
    condition     = var.web.certificate_arn == null || can(regex("^arn:aws[a-zA-Z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-zA-Z0-9-]+$", var.web.certificate_arn))
    error_message = "web.certificate_arn must be null or an ACM certificate ARN (arn:<partition>:acm:<region>:<account>:certificate/<id>)."
  }

  # W5
  validation {
    condition = contains([
      "ELBSecurityPolicy-TLS13-1-2-2021-06",
      "ELBSecurityPolicy-TLS13-1-2-Res-2021-06",
      "ELBSecurityPolicy-TLS13-1-3-2021-06",
      "ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04",
      "ELBSecurityPolicy-TLS13-1-2-Res-FIPS-2023-04",
      "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04",
    ], var.web.ssl_policy)
    error_message = "web.ssl_policy must be one of the allowed TLS 1.2+ policies: ELBSecurityPolicy-TLS13-1-2-2021-06, ELBSecurityPolicy-TLS13-1-2-Res-2021-06, ELBSecurityPolicy-TLS13-1-3-2021-06, ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04, ELBSecurityPolicy-TLS13-1-2-Res-FIPS-2023-04, ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04."
  }
}

variable "app" {
  description = <<-EOT
    App tier (server fleet) settings.

    - `name`: Name for the ASG, IAM role and instance profile. It prefixes the launch template, security group and target group, and is the `Name` tag for app-tier resources.
    - `instance_type`: EC2 instance type. Its architecture must match the selected AMI (checked in `check.tf`).
    - `port`: Port the application listens on. It is the only port the load balancer can reach.
    - `health_check_path`: HTTP path the load balancer probes. Servers that fail it are replaced.
    - `health_check_grace_period`: Seconds after launch before failed health checks count. Size it to cover boot plus user data.
    - `min_size`: Minimum fleet size.
    - `max_size`: Maximum fleet size.
    - `root_volume_size`: Root EBS volume size in GiB (gp3, always encrypted).
    - `user_data`: Plain-text boot script. The module base64-encodes it. Do not embed secrets, because anyone with instance metadata or DescribeInstanceAttribute access can read user data.
    - `ebs_kms_key_arn`: Customer-managed KMS key ARN for the root volume. When null, the AWS-managed `aws/ebs` key is used. The key policy MUST let the `AWSServiceRoleForAutoScaling` service-linked role use the key (`kms:CreateGrant`, `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`). Otherwise instances terminate at launch with `Client.InvalidKMSKey.InvalidState`.
    - `managed_policy_arns`: Managed IAM policies attached to the instance role, keyed by a static name you choose. The default grants Session Manager only, with no SSH. Setting this map replaces the default, so keep `ssm` if you need it. To read the database secret, add a policy granting `secretsmanager:GetSecretValue` on `db_instance_master_user_secret_arn`, plus `kms:Decrypt` if you use a secret CMK. Callers outside the `aws` partition must override the default ARN.
  EOT
  type = object({
    name                      = optional(string, "three-tier-app")
    instance_type             = optional(string, "t3.micro")
    port                      = optional(number, 8080)
    health_check_path         = optional(string, "/")
    health_check_grace_period = optional(number, 300)
    min_size                  = optional(number, 2)
    max_size                  = optional(number, 4)
    root_volume_size          = optional(number, 20)
    user_data                 = optional(string)
    ebs_kms_key_arn           = optional(string)
    managed_policy_arns = optional(map(string), {
      ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    })
  })
  default = {}

  # A1
  validation {
    condition     = length(var.app.name) <= 64
    error_message = "app.name must be at most 64 characters."
  }

  # A2
  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.app.name))
    error_message = "app.name must contain only alphanumerics and hyphens, and must not start or end with a hyphen."
  }

  # A3
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.app.instance_type))
    error_message = "app.instance_type must be an EC2 instance type in <family>.<size> form, for example t3.micro."
  }

  # A4
  validation {
    condition     = var.app.port >= 1 && var.app.port <= 65535
    error_message = "app.port must be between 1 and 65535."
  }

  # A5
  validation {
    condition     = startswith(var.app.health_check_path, "/")
    error_message = "app.health_check_path must start with \"/\"."
  }

  # A6
  validation {
    condition     = length(var.app.health_check_path) <= 1024
    error_message = "app.health_check_path must be at most 1024 characters."
  }

  # A7
  validation {
    condition     = var.app.health_check_grace_period >= 0
    error_message = "app.health_check_grace_period must be 0 or greater."
  }

  # A8
  validation {
    condition     = var.app.min_size >= 0
    error_message = "app.min_size must be 0 or greater."
  }

  # A9
  validation {
    condition     = var.app.max_size >= 1
    error_message = "app.max_size must be 1 or greater."
  }

  # A10
  validation {
    condition     = var.app.max_size >= var.app.min_size
    error_message = "app.max_size must be greater than or equal to app.min_size."
  }

  # A11
  validation {
    condition     = var.app.root_volume_size >= 8 && var.app.root_volume_size <= 16384
    error_message = "app.root_volume_size must be between 8 and 16384 GiB."
  }

  # A12
  validation {
    condition     = var.app.user_data == null || length(var.app.user_data) <= 16384
    error_message = "app.user_data must be null or at most 16384 characters."
  }

  # A13
  validation {
    condition     = var.app.ebs_kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.app.ebs_kms_key_arn))
    error_message = "app.ebs_kms_key_arn must be null or a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<id>). Aliases are not accepted."
  }

  # A14
  validation {
    condition     = alltrue([for arn in values(var.app.managed_policy_arns) : can(regex("^arn:aws[a-zA-Z-]*:iam::([0-9]{12}|aws):policy/.+$", arn))])
    error_message = "app.managed_policy_arns values must all be IAM managed policy ARNs (arn:<partition>:iam::<account|aws>:policy/<name>)."
  }
}

variable "ami" {
  description = <<-EOT
    App server image selection. The most recent match wins.

    - `owners`: AMI owner account IDs or aliases (`amazon`, `self`). It is always set, so image lookups are never unscoped.
    - `name_pattern`: AMI name filter (wildcards allowed). A newer matching image rolls the fleet on the next apply.
  EOT
  type = object({
    owners       = optional(list(string), ["amazon"])
    name_pattern = optional(string, "al2023-ami-2023.*-x86_64")
  })
  default = {}

  # M1
  validation {
    condition     = length(var.ami.owners) > 0
    error_message = "ami.owners must contain at least one owner account ID or alias."
  }

  # M2
  validation {
    condition     = length(var.ami.name_pattern) > 0
    error_message = "ami.name_pattern must not be empty."
  }
}

variable "database" {
  description = <<-EOT
    Data tier settings. When null, no data tier is created. When set (even `{}`), a single encrypted PostgreSQL instance is created in the database subnets.

    - `name`: DB identifier, subnet group name, security group prefix and `Name` tag. The final snapshot is `<name>-final`.
    - `engine_version`: PostgreSQL **major** version, 15 or later. Minor versions upgrade automatically, and 15+ enforces TLS by default.
    - `instance_class`: RDS instance class.
    - `allocated_storage`: Storage in GiB (gp3, always encrypted).
    - `db_name`: Name of the initial database.
    - `username`: Master username. RDS generates the password and stores it in Secrets Manager.
    - `port`: Database port. Only the app tier can reach it.
    - `multi_az`: Keep a synchronous standby in a second AZ.
    - `backup_retention_period`: Days of automated backups. Backups cannot be disabled.
    - `deletion_protection`: Block deletion of the database. To destroy, set it to false and apply first.
    - `skip_final_snapshot`: Skip the `<name>-final` snapshot on destroy. Set it to true only for disposable environments.
    - `kms_key_arn`: Customer-managed KMS key ARN for storage encryption. When null, `aws/rds` is used. Changing it replaces the database.
    - `master_user_secret_kms_key_arn`: Customer-managed KMS key ARN for the master-password secret. When null, `aws/secretsmanager` is used.
  EOT
  type = object({
    name                           = optional(string, "three-tier-app-db")
    engine_version                 = optional(string, "16")
    instance_class                 = optional(string, "db.t4g.micro")
    allocated_storage              = optional(number, 20)
    db_name                        = optional(string, "app")
    username                       = optional(string, "app_admin")
    port                           = optional(number, 5432)
    multi_az                       = optional(bool, true)
    backup_retention_period        = optional(number, 7)
    deletion_protection            = optional(bool, true)
    skip_final_snapshot            = optional(bool, false)
    kms_key_arn                    = optional(string)
    master_user_secret_kms_key_arn = optional(string)
  })
  default = null

  # D1 (cross-variable)
  validation {
    condition     = var.database == null || length(var.vpc.database_subnet_ids) >= 2
    error_message = "database requires vpc.database_subnet_ids to contain at least 2 subnets."
  }

  # D2
  validation {
    condition     = var.database == null || length(var.database.name) <= 63
    error_message = "database.name must be at most 63 characters."
  }

  # D3
  validation {
    condition     = var.database == null || can(regex("^[a-z](-?[a-z0-9])*$", var.database.name))
    error_message = "database.name must start with a lowercase letter, contain only lowercase letters, digits and single hyphens, and must not end with a hyphen."
  }

  # D4
  validation {
    condition     = var.database == null || can(regex("^[0-9]+$", var.database.engine_version))
    error_message = "database.engine_version must be a PostgreSQL major version only (for example \"16\"), without a minor version."
  }

  # D5
  validation {
    condition     = var.database == null || try(tonumber(var.database.engine_version) >= 15, false)
    error_message = "database.engine_version must be 15 or later (PostgreSQL 15+ enforces TLS by default)."
  }

  # D6
  validation {
    condition     = var.database == null || startswith(var.database.instance_class, "db.")
    error_message = "database.instance_class must be an RDS instance class starting with \"db.\"."
  }

  # D7
  validation {
    condition     = var.database == null || (var.database.allocated_storage >= 20 && var.database.allocated_storage <= 65536)
    error_message = "database.allocated_storage must be between 20 and 65536 GiB."
  }

  # D8
  validation {
    condition     = var.database == null || can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.database.db_name))
    error_message = "database.db_name must start with a letter, contain only letters, digits and underscores, and be at most 63 characters."
  }

  # D9
  validation {
    condition     = var.database == null || can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.database.username))
    error_message = "database.username must start with a letter, contain only letters, digits and underscores, and be at most 63 characters."
  }

  # D10
  validation {
    condition     = var.database == null || !contains(["postgres", "admin", "root", "rdsadmin"], lower(var.database.username))
    error_message = "database.username must not be a default or reserved name (postgres, admin, root, rdsadmin), in any case."
  }

  # D11
  validation {
    condition     = var.database == null || (var.database.port >= 1150 && var.database.port <= 65535)
    error_message = "database.port must be between 1150 and 65535."
  }

  # D12
  validation {
    condition     = var.database == null || (var.database.backup_retention_period >= 1 && var.database.backup_retention_period <= 35)
    error_message = "database.backup_retention_period must be between 1 and 35 days. Backups cannot be disabled."
  }

  # D13
  validation {
    condition     = var.database == null || var.database.kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.database.kms_key_arn))
    error_message = "database.kms_key_arn must be null or a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<id>). Aliases are not accepted."
  }

  # D14
  validation {
    condition     = var.database == null || var.database.master_user_secret_kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.database.master_user_secret_kms_key_arn))
    error_message = "database.master_user_secret_kms_key_arn must be null or a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<id>). Aliases are not accepted."
  }
}

variable "tags" {
  description = "Tags applied to every resource beneath the module's `Name` tag. A `Name` key here is ignored."
  type        = map(string)
  default     = {}
}

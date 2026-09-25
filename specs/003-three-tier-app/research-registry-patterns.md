## Research: How do existing registry modules structure ALB + ASG + RDS interfaces, and what should we borrow or avoid?

### Decision

Author native resources directly (no public sub-modules, which all require AWS provider 6.x). Accept the org vpc module's outputs unchanged as a `vpc` object of `map(string)` subnet maps keyed by subnet name. Borrow the public modules' secure defaults and coupling patterns: IMDSv2 defaults, `latest_version` launch template coupling, RDS-managed master password, and one resource per SG rule. Do not borrow their `create_*` booleans, `this` names, or listener/target group maps.

### Resources Identified

- **Primary Resources**: `aws_lb.web`, `aws_autoscaling_group.app`, `aws_db_instance.database` (conditional)
- **Supporting Resources** (file per service):
  - `elb.tf`: `aws_lb.web`, `aws_lb_target_group.app`, `aws_lb_listener.http` (always), `aws_lb_listener.https` (`count` 0/1 on `alb.certificate_arn != null`)
  - `ec2.tf`: `aws_launch_template.app`
  - `autoscaling.tf`: `aws_autoscaling_group.app`
  - `iam.tf`: `aws_iam_role.app`, `aws_iam_instance_profile.app`, `aws_iam_role_policy_attachment.app` (`for_each` over `app.managed_policy_arns`); the assume-role policy document goes in `main.tf` as a data source
  - `rds.tf`: `aws_db_subnet_group.database`, `aws_db_instance.database` (both `count` 0/1 on `var.database != null`)
  - `vpc.tf`: `aws_security_group.alb` / `.app` / `.database`, plus one `aws_vpc_security_group_{ingress,egress}_rule` per rule
  - `main.tf`: `data.aws_ami.selected`, `data.aws_partition.current`, `data.aws_iam_policy_document.app_assume_role`, `data.aws_ec2_instance_type.app`, `data.aws_subnet.public` / `.database` (`for_each` over the input maps)
  - `check.tf`: assertions on the data sources above
- **Key Arguments**: see "Proposed variable interface" below
- **Key Outputs**: see "Proposed output list" below
- **Security Considerations**:
  - IMDSv2 required with hop limit 1.
  - RDS: `storage_encrypted = true` (not configurable), `publicly_accessible = false` (not configurable), `manage_master_user_password = true`, `deletion_protection = true` by default, and a final snapshot on destroy.
  - Security groups reference other security groups. `0.0.0.0/0` is allowed only on ALB ingress (80, and 443 when HTTPS is on) and app egress 443.
  - TLS 1.2+ policy on HTTPS.
  - Optional CMK ARNs, which the module never creates.

---

### 1. Private registry: `craigsloggett-lab/vpc/aws` (latest 0.1.0)

This is the only module in the org registry. The output definitions below were verified from the source `outputs.tf` (github.com/craigsloggett-lab/terraform-aws-vpc).

| Output | Expression | Effective type | Key semantics |
|---|---|---|---|
| `vpc_id` | `aws_vpc.this.id` | `string` | n/a |
| `public_subnet_ids` | `{ for k, s in aws_subnet.public : k => s.id }` | `map(string)` | keyed by **subnet short name** (e.g. `web-a`) |
| `private_subnet_ids` | `{ for k, s in aws_subnet.private : k => s.id }` | `map(string)` | keyed by **subnet short name** (e.g. `app-a`) |
| `database_subnet_ids` | `{ for k, s in aws_subnet.database : k => s.id }` | `map(string)` | keyed by **subnet short name** (e.g. `db-a`) |
| `database_subnet_group_name` | `try(aws_db_subnet_group.this[0].name, null)` | `string` (nullable) | n/a |
| `azs` | sorted distinct AZs over all tiers | `list(string)` | n/a |

Map keys are **not AZs**. They are the consumer's own keys from the vpc module's `public_subnets` / `private_subnets` / `database_subnets` inputs, of type `map(object({cidr_block, availability_zone, tags}))`. The vpc example uses keys like `web-a`, `app-b`, `db-a`. Only the NAT/route-table outputs (`nat_gateway_ids`, `private_route_table_ids`) are keyed by AZ. What this means for our module:

- The keys come from literal input maps, so they are **known at plan**. The values (IDs) are unknown until the VPC is applied. Using `for_each = var.vpc.public_subnet_ids` on data sources is therefore safe. Unknown values only defer the data read.
- Pass subnets to resources as `values(var.vpc.<tier>_subnet_ids)`. Do not assume one subnet per AZ, and do not derive AZs from keys. To get AZs, use `data.aws_subnet.<tier>[*].availability_zone` in `check.tf`.
- An empty tier is `{}`, not null. The vpc module always returns a map, even when a tier has no subnets.
- The vpc module can also create a DB subnet group (`create_database_subnet_group = true` by default). The issue requirements say our module creates its own `aws_db_subnet_group`, so we do not need `database_subnet_group_name` as an input. See Alternatives.
- The vpc module pins `aws >= 5.0, < 6.0` and Terraform `>= 1.14`, which matches our `~> 5.0` provider pin.

Our `vpc` input therefore takes the outputs directly:

```hcl
module "three_tier_app" {
  vpc = {
    vpc_id              = module.vpc.vpc_id
    public_subnet_ids   = module.vpc.public_subnet_ids
    private_subnet_ids  = module.vpc.private_subnet_ids
    database_subnet_ids = module.vpc.database_subnet_ids
  }
}
```

### 2. Public registry pattern study

Every current terraform-aws-modules release requires AWS provider 6.x: alb 10.5.1 (`>= 6.28`), autoscaling 9.3.2 (`>= 6.56`), rds 7.2.2 (`>= 6.28`), security-group 6.0.0 (`>= 6.29`). They **cannot be called** from a `~> 5.0` module, so we use them as pattern references only. Native resources are required anyway by constitution section 1.1.

#### terraform-aws-modules/alb 10.5.1
- **Input shape**: flat scalars (`name`, `internal`, `subnets list(string)`, `vpc_id`, `enable_deletion_protection`, `drop_invalid_header_fields = true`) plus large generic maps `listeners map(object)` and `target_groups map(object)`. The ALB security group is built in from `security_group_ingress_rules` / `security_group_egress_rules` maps, which use `aws_vpc_security_group_*_rule` resources.
- **HTTPS vs HTTP**: there is no built-in toggle. The consumer writes an `http` listener with `redirect = { port = "443", protocol = "HTTPS", status_code = "HTTP_301" }` and an `https` listener with `certificate_arn` and `forward = { target_group_key = ... }`. The `dynamic "redirect"` / `dynamic "forward"` blocks are driven by which sub-object is non-null. When protocol is HTTPS/TLS, `ssl_policy` defaults to `ELBSecurityPolicy-TLS13-1-3-2021-06`.
- **Outputs**: bare `arn`, `id`, `dns_name`, `zone_id`, `arn_suffix`, `security_group_id`, plus maps `listeners` and `target_groups`.
- **Borrow**: `drop_invalid_header_fields = true`, a default TLS policy when a cert is present, a redirect-by-dynamic-block driven by presence of a value, and `aws_vpc_security_group_*_rule` resources.
- **Avoid**:
  - Generic listener/target-group maps. We have exactly one TG, one HTTP listener and an optional HTTPS listener, so maps are over-generalised and hide secure defaults.
  - `create` booleans.
  - `this` resource names.
  - Bare output names. In a composite module, `arn` is ambiguous, so prefix with `alb_`.

#### terraform-aws-modules/autoscaling 9.3.2
- **Input shape**: about 150 flat inputs. The launch template is embedded (`create_launch_template = true`, `image_id`, `instance_type`, `user_data` which must already be base64), and there is an optional IAM instance profile (`create_iam_instance_profile`, `iam_role_policies map(string)`).
- **Launch template / ASG coupling** (verified in `main.tf`):
  - `launch_template_version = var.create_launch_template && var.launch_template_version == null ? aws_launch_template.this[0].latest_version : var.launch_template_version`, used as `launch_template { version = ... }`.
  - The ASG has `lifecycle { create_before_destroy = true, ignore_changes = [desired_capacity (optional), target_group_arns, load_balancers] }`.
  - An `instance_refresh` object (`strategy`, `preferences.min_healthy_percentage`, etc.) rolls instances when the LT version changes.
  - Target groups are attached through a separate `aws_autoscaling_traffic_source_attachment` map, not the inline `target_group_arns`.
- **Secure defaults**: `metadata_options = { http_endpoint = "enabled", http_tokens = "required", http_put_response_hop_limit = 1 }`, and `enable_monitoring = true`.
- **Outputs**: `autoscaling_group_name` / `_arn` / `_id`, `launch_template_id` / `_arn` / `_latest_version`, `iam_role_arn` / `_name`, `iam_instance_profile_arn`.
- **Borrow**:
  - `version = aws_launch_template.app.latest_version`, never `$Latest`, so that a new LT version is a planned diff.
  - An `instance_refresh { strategy = "Rolling" }` block so LT changes roll the fleet.
  - IAM policy attachments as a `map(string)` keyed by a static name. This avoids unknown-key errors when a consumer passes a policy ARN created in the same apply. `for_each = toset(list_of_arns)` would fail in that case.
  - The IMDSv2 defaults.
  - The `autoscaling_group_*` / `launch_template_*` output prefixes.
- **Avoid**:
  - The separate traffic-source attachment resource. It is needed only for their generic case, and mixing it with inline `target_group_arns` causes perpetual diffs. With a single TG we set inline `target_group_arns = [aws_lb_target_group.app.arn]` and `health_check_type = "ELB"`.
  - Requiring pre-encoded user data. We `base64encode()` inside the module so the consumer passes plain text.
  - `ignore_changes` on `desired_capacity`. Only add it if the design adds scaling policies.

#### terraform-aws-modules/rds 7.2.2
- **Input shape**: about 140 flat inputs. Toggles are booleans: `create_db_instance`, `create_db_subnet_group = false`, `create_db_parameter_group`, `create_db_option_group`, `create_monitoring_role`.
- **Secure defaults**: `storage_encrypted = true`, `publicly_accessible = false`, `manage_master_user_password = true`, `copy_tags_to_snapshot = true`. Their `deletion_protection = false`, `multi_az = false` and `skip_final_snapshot = false` are weaker than our requirements.
- **Outputs**: prefixed with `db_instance_` (`db_instance_address`, `db_instance_endpoint`, `db_instance_port`, `db_instance_arn`, `db_instance_identifier`, `db_instance_master_user_secret_arn`), plus `db_subnet_group_id` / `_arn`.
- **Borrow**:
  - `manage_master_user_password = true` with an optional `master_user_secret_kms_key_id`, and output the secret ARN via `aws_db_instance.database[0].master_user_secret[0].secret_arn`.
  - `kms_key_id` null, which falls back to the AWS-managed `aws/rds` key.
  - The `db_instance_*` output prefix.
  - `final_snapshot_identifier` derived from the identifier.
- **Avoid**:
  - `create_*` booleans. Presence of `var.database` is our toggle.
  - Parameter/option-group creation, which is out of scope.
  - Their insecure defaults for deletion protection and Multi-AZ.

#### terraform-aws-modules/security-group 6.0.0
- **Input shape**: `ingress_rules` / `egress_rules` as `map(object({ cidr_ipv4, referenced_security_group_id, from_port, to_port, ip_protocol = "tcp", ... }))`, rendered with `for_each` into `aws_vpc_security_group_ingress_rule` / `_egress_rule`. There is also `enable_exclusive_rules = true`.
- **Borrow**: one `aws_vpc_security_group_*_rule` per rule, and `referenced_security_group_id` for tier-to-tier rules.
- **Avoid**: consumer-supplied rule maps. Our rules are fixed by architecture, so write each rule out as a named resource per constitution section 2.2 (`alb_http`, `alb_https`, `app_from_alb`, `app_https`, `app_to_database`, `database_from_app`). Leave out `revoke_rules_on_delete`. Leave out `enable_exclusive_rules`, which needs provider 6.x.

### 3. Conditional HTTPS vs HTTP listener pattern (recommended)

- `aws_lb_listener.https`:
  - Uses `count = var.alb.certificate_arn != null ? 1 : 0`.
  - Settings: port 443, `HTTPS`, `ssl_policy = var.alb.ssl_policy`, `certificate_arn`, and a `forward` action to `aws_lb_target_group.app`.
- `aws_lb_listener.http`:
  - Is **always** created on port 80.
  - Its `default_action.type` is `local.https_enabled ? "redirect" : "forward"`.
  - It has a `dynamic "redirect"` block (`for_each = local.https_enabled ? [1] : []`) with `port = "443"`, `protocol = "HTTPS"` and `status_code = "HTTP_301"`, and `target_group_arn` only when forwarding (`local.https_enabled ? null : aws_lb_target_group.app.arn`).
  - The `dynamic` block is justified under constitution section 2.5 because the block count (0/1) is input-driven.
  - Rationale: two separate `count`-toggled port-80 resources (`http_redirect` vs `http_forward`) would, when a cert is added or removed, create one listener and destroy the other within one apply. There is no guaranteed ordering, so this risks `DuplicateListener` on port 80. A single resource updates in place.
- The ALB SG ingress rule `alb_https` (443) uses `count` on the same condition. `alb_http` (80) is always present because it is needed for the redirect.
- `ssl_policy` default: `ELBSecurityPolicy-TLS13-1-2-2021-06`, which allows TLS 1.2 and 1.3 and is the AWS-recommended ALB policy. The alb module's `TLS13-1-3` default rejects TLS 1.2 clients, which is too strict for a general-purpose default.

### 4. RDS toggle pattern (recommended)

- `variable "database"` is a top-level `object({...})` with **`default = null`**. Its presence is the toggle (constitution section 1.1).
- `aws_db_subnet_group.database`, `aws_db_instance.database`, `aws_security_group.database`, `aws_vpc_security_group_ingress_rule.database_from_app` and `aws_vpc_security_group_egress_rule.app_to_database` all use `count = var.database != null ? 1 : 0`.
- Use `local.database_enabled = var.database != null` so every `count` reads the same way.
- Cross-variable rule: when `database != null`, `vpc.database_subnet_ids` must be non-empty. Terraform >= 1.9 allows a `validation` on `var.database` to reference `var.vpc`, which fits our `~> 1.14` floor (matching the org vpc module).
- The DB security group ingress references the app security group. App egress to the DB references the DB security group.

### 5. Proposed variable interface

Required variables are the minimum: `vpc` only. Every other object defaults to `{}`, except `database`, which defaults to `null`.

```hcl
# Required
variable "vpc" {
  type = object({
    vpc_id              = string
    public_subnet_ids   = map(string) # keyed by subnet name, as output by craigsloggett-lab/vpc/aws
    private_subnet_ids  = map(string)
    database_subnet_ids = optional(map(string), {})
  })
}

# Optional
variable "alb" {
  type = object({
    name                = optional(string, "three-tier-web")
    certificate_arn     = optional(string)             # null => HTTP only; set => HTTPS + 80->443 redirect
    ssl_policy          = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")
    ingress_cidr_blocks = optional(set(string), ["0.0.0.0/0"])
  })
  default = {}
}

variable "app" {
  type = object({
    name                = optional(string, "three-tier-app")
    instance_type       = optional(string, "t3.micro")
    port                = optional(number, 8080)
    health_check_path   = optional(string, "/")
    min_size            = optional(number, 2)
    max_size            = optional(number, 4)
    desired_capacity    = optional(number, 2)
    user_data           = optional(string)             # plain text; module base64encodes
    root_volume_size    = optional(number, 20)
    ebs_kms_key_arn     = optional(string)             # null => AWS-managed aws/ebs key
    managed_policy_arns = optional(map(string), {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    })
  })
  default = {}
}

variable "ami" {
  type = object({
    owners = optional(list(string), ["amazon"])
    name   = optional(string, "al2023-ami-2023.*-x86_64")
  })
  default = {}
}

variable "database" {
  type = object({
    name                          = optional(string, "three-tier-db")   # DB identifier + Name tag
    engine_version                = optional(string, "16")
    instance_class                = optional(string, "db.t4g.micro")
    allocated_storage             = optional(number, 20)
    db_name                       = optional(string, "app")
    username                      = optional(string, "app_admin")
    port                          = optional(number, 5432)
    multi_az                      = optional(bool, true)
    backup_retention_period       = optional(number, 7)
    deletion_protection           = optional(bool, true)
    skip_final_snapshot           = optional(bool, false)
    kms_key_arn                   = optional(string)   # storage; null => aws/rds
    master_user_secret_kms_key_arn = optional(string)  # null => aws/secretsmanager
  })
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

Validation blocks, one rule each (error message names the path):

- `vpc`:
  - `vpc.vpc_id` must start with `vpc-`.
  - `vpc.public_subnet_ids` has ≥ 2 entries (ALB needs 2 AZs).
  - `vpc.private_subnet_ids` has ≥ 1 entry.
  - Every subnet ID value starts with `subnet-`, one block per tier. Note that `alltrue` over unknown values is deferred at plan, so this is safe.
- `alb`:
  - `alb.name` is ≤ 32 characters and matches `^[a-zA-Z0-9-]+$` without a leading or trailing hyphen.
  - `alb.certificate_arn`, when set, matches `^arn:aws[a-z-]*:acm:`.
  - `alb.ssl_policy` starts with `ELBSecurityPolicy-`.
- `app`:
  - `app.port` is between 1 and 65535.
  - `app.health_check_path` starts with `/`.
  - `min_size <= desired_capacity`.
  - `desired_capacity <= max_size`.
  - `min_size >= 0`.
  - `app.name` is ≤ 32 characters, because it is also the target group name.
- `ami`:
  - `ami.owners` is non-empty.
  - `ami.name` is non-empty.
- `database`:
  - `database == null || length(vpc.database_subnet_ids) >= 2` (cross-variable, TF ≥ 1.9).
  - `backup_retention_period` is between 1 and 35 (≥ 1 keeps backups on).
  - `allocated_storage >= 20`.
  - `name` matches the RDS identifier regex `^[a-z][a-z0-9-]{0,62}$`.
  - `username` is not `postgres` or another reserved word.

Every validation on `database` must be null-safe, for example `var.database == null || ...`.

`check.tf` assertions, which need data sources and produce warnings rather than blocking:

- Every subnet in `data.aws_subnet.public` / `.private` / `.database` has `vpc_id == var.vpc.vpc_id`.
- Public subnets span ≥ 2 distinct AZs.
- Database subnets span ≥ 2 distinct AZs when the database is enabled.
- `data.aws_ami.selected.architecture` is in `data.aws_ec2_instance_type.app.supported_architectures`.

Name tags: `tags = merge(var.tags, { Name = var.<object>.name })` on every resource. The launch template also sets `tag_specifications` for `instance` and `volume`, and the ASG sets `tag { key = "Name", propagate_at_launch = true }`. Derived names such as `"${var.app.name}-alb"` for security groups and `"${var.database.name}-final"` for the snapshot are built in `locals.tf`.

Design note for the design agent: static default names collide if two instances of the module run in the same account and region. ALB, TG, ASG, IAM role and DB identifier names must be unique. Document that the examples override every `name`. The alternative is to use `name_prefix` on the IAM role, launch template and security groups, but that breaks the "Name from object's name" rule for those resources. Recommendation: keep explicit names, and override them in examples.

### 6. Proposed output list

All outputs from resources behind a `count` use `try(...[0].attr, null)`.

| Output | Type | Source | Conditional |
|---|---|---|---|
| `alb_arn` | string | `aws_lb.web.arn` | always |
| `alb_arn_suffix` | string | `aws_lb.web.arn_suffix` (CloudWatch dimension) | always |
| `alb_dns_name` | string | `aws_lb.web.dns_name` | always |
| `alb_zone_id` | string | `aws_lb.web.zone_id` (Route 53 alias) | always |
| `alb_security_group_id` | string | `aws_security_group.alb.id` | always |
| `http_listener_arn` | string | `aws_lb_listener.http.arn` | always |
| `https_listener_arn` | string | `try(aws_lb_listener.https[0].arn, null)` | `alb.certificate_arn` |
| `target_group_arn` | string | `aws_lb_target_group.app.arn` | always |
| `autoscaling_group_name` | string | `aws_autoscaling_group.app.name` | always |
| `autoscaling_group_arn` | string | `aws_autoscaling_group.app.arn` | always |
| `launch_template_id` | string | `aws_launch_template.app.id` | always |
| `launch_template_latest_version` | number | `aws_launch_template.app.latest_version` | always |
| `app_security_group_id` | string | `aws_security_group.app.id` | always |
| `iam_role_arn` | string | `aws_iam_role.app.arn` | always |
| `iam_role_name` | string | `aws_iam_role.app.name` (so consumers can attach more policies) | always |
| `iam_instance_profile_arn` | string | `aws_iam_instance_profile.app.arn` | always |
| `ami_id` | string | `data.aws_ami.selected.id` | always |
| `db_instance_identifier` | string | `try(aws_db_instance.database[0].identifier, null)` | `database` |
| `db_instance_arn` | string | `try(aws_db_instance.database[0].arn, null)` | `database` |
| `db_instance_address` | string | `try(aws_db_instance.database[0].address, null)` | `database` |
| `db_instance_endpoint` | string | `try(aws_db_instance.database[0].endpoint, null)` (host:port) | `database` |
| `db_instance_port` | number | `try(aws_db_instance.database[0].port, null)` | `database` |
| `db_instance_master_user_secret_arn` | string | `try(aws_db_instance.database[0].master_user_secret[0].secret_arn, null)` | `database` |
| `db_subnet_group_name` | string | `try(aws_db_subnet_group.database[0].name, null)` | `database` |
| `database_security_group_id` | string | `try(aws_security_group.database[0].id, null)` | `database` |

None of these outputs are secrets. The password lives only in Secrets Manager, and the ARN is not sensitive.

### Rationale

- The org vpc module's `outputs.tf` confirms `map(string)` maps keyed by subnet name. A `map(string)` field in our `vpc` object is therefore the only type that accepts `module.vpc.*_subnet_ids` without the consumer wrapping them in `values()`.
- The public modules converge on the same secure defaults: IMDSv2 (autoscaling), `manage_master_user_password` and `storage_encrypted` (rds), `drop_invalid_header_fields` (alb), and per-rule SG resources (security-group). These match constitution sections 3.2 and 2.2.
- Their generic `create_*` booleans and map-of-everything inputs conflict with constitution section 1.1 (presence-of-object toggles) and section 2.2 (descriptive names, never `this`). Our architecture is fixed, so fixed named resources give clearer tests and plans.

### Alternatives Considered

| Alternative | Why Not |
|---|---|
| Call terraform-aws-modules alb/autoscaling/rds as child modules | All current releases require AWS provider ≥ 6.28, which is incompatible with the mandated `~> 5.0`. The constitution requires native resources, and the child modules bring `this` naming and `create_*` flags. |
| `vpc` subnet inputs as `list(string)` | Consumers would have to write `values(module.vpc.private_subnet_ids)`, and it breaks the "accept vpc outputs directly" requirement. |
| Key subnets by AZ in our module | The vpc module keys by subnet name, not AZ, and allows several subnets per AZ. Re-keying would need apply-time data. |
| Reuse the vpc module's `database_subnet_group_name` instead of creating `aws_db_subnet_group` | The issue explicitly lists `aws_db_subnet_group`, and that output is null when the vpc module's toggle is off. It could be added later as an optional `vpc.database_subnet_group_name` override. |
| Generic `listeners` / `target_groups` maps (alb module style) | Over-generalised for one TG and at most two listeners. They hide the secure HTTP→HTTPS redirect default. |
| Two `count`-toggled port-80 listeners (redirect vs forward) | Toggling the cert could produce a create/destroy race on port 80. A single listener with a `dynamic "redirect"` updates in place. |
| `aws_autoscaling_traffic_source_attachment` / `aws_autoscaling_attachment` | This is a second source of truth for target groups, and mixing it with inline `target_group_arns` causes diff churn. Inline is simpler for a single TG. |
| `managed_policy_arns` as `set(string)` with `for_each = toset(...)` | Fails with "Invalid for_each argument" when an ARN is unknown at plan. A `map(string)` keyed by static names avoids this, following the autoscaling module's `iam_role_policies`. |
| `launch_template { version = "$Latest" }` | The LT change does not show as an ASG diff and does not trigger instance refresh. `latest_version` does both. |
| `enable_database` boolean | Constitution section 1.1: when the feature has configuration, presence of the object is the toggle. |

### Sources

- Private registry: `craigsloggett-lab/vpc/aws` 0.1.0 (HCP Terraform org `craigsloggett-lab`); source `outputs.tf`, `locals.tf` and `examples/complete/main.tf` at https://github.com/craigsloggett-lab/terraform-aws-vpc
- https://registry.terraform.io/modules/terraform-aws-modules/alb/aws/10.5.1 (source `main.tf`: listener `for_each`, `dynamic "redirect"`, `ssl_policy` default)
- https://registry.terraform.io/modules/terraform-aws-modules/autoscaling/aws/9.3.2 (source `main.tf` line 8 `launch_template_version` coupling, `create_before_destroy`, `ignore_changes`, traffic source attachment)
- https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/7.2.2
- https://registry.terraform.io/modules/terraform-aws-modules/security-group/aws/6.0.0
- AWS: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html (TLS13-1-2-2021-06 recommended policy)
- AWS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html (RDS-managed master password)
- AWS: https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html
- Constitution: /workspace/.foundations/memory/module-constitution.md sections 1.1, 2.1–2.5, 3.2, 3.3
- Tracking issue #3 (requirements and clarification summary)

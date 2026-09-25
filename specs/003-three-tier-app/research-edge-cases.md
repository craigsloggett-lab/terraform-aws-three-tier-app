## Research: Edge cases, failure modes, and test strategy for three-tier-app

### Decision

Use `count = <cond> ? 1 : 0` for every optional singleton (HTTPS listener, the whole RDS tier), a single always-present HTTP listener whose `default_action` switches between `redirect` and `forward` through a `dynamic` block, `try(x[0].attr, null)` in outputs, one `validation` block per rule (including cross-variable rules, supported on Terraform 1.15), a small `check.tf` (subnets belong to the VPC, AMI architecture matches the instance type), and mock-provider plan tests that supply `mock_data` for every data source and `override_resource { override_during = plan }` wherever an assertion compares provider-computed values.

Most of the test-harness behaviour below was checked by running experiments locally (Terraform v1.15.2, hashicorp/aws ~> 5.0, `mock_provider "aws"`, `command = plan`). Those findings are marked **[verified]**. Anything else comes from provider or AWS docs.

---

### Resources Identified

- **Primary Resource**: `aws_lb` (ALB, always created). Conditional subtrees hang off it.
- **Supporting Resources (conditional)**:
  - `aws_lb_listener.https` has `count = var.<alb>.certificate_arn != null ? 1 : 0`.
  - `aws_lb_listener.http` is always created. Its `default_action` is `redirect` (to HTTPS 443, `HTTP_301`) when a certificate is given and `forward` to the target group otherwise.
  - RDS tier: `aws_db_subnet_group.<name>`, `aws_security_group.database`, `aws_vpc_security_group_ingress_rule.database_from_app`, `aws_vpc_security_group_egress_rule.app_to_database`, `aws_db_instance.<name>`. Each has `count = var.database != null ? 1 : 0`.
  - Check-only data sources, scoped inside `check` blocks: `aws_subnets` (filter `vpc-id`) and `aws_ec2_instance_type`.
- **Key Arguments**: see the gotchas in section 5 (`name_prefix`, `user_data`, `final_snapshot_identifier`, `manage_master_user_password`, `deletion_protection`, `referenced_security_group_id`).
- **Key Outputs**: `https_listener_arn` (`string`, null when no cert), `db_instance_endpoint`, `db_instance_address`, `db_instance_arn`, `db_master_user_secret_arn`, `db_security_group_id` (all `string`, null when `database == null`).
- **Security Considerations**: HTTP always redirects when a cert exists. The DB is reachable only from the app SG through SG references. `manage_master_user_password = true` keeps the password out of state. `storage_encrypted = true`, `publicly_accessible = false` and `deletion_protection` default to the secure value but are configurable, so examples can destroy.

---

### 1. Conditional resources

**count vs for_each.** The constitution (§2.5) allows `count` only as a 0/1 toggle and prefers `for_each` for fan-out. Every toggle in this module is a singleton, so use `count`. Keep `for_each` for input-driven multiples, e.g. `for_each = var.vpc.app_subnet_ids` if subnets are ever given as a map. Do not use `for_each = var.database == null ? {} : { main = var.database }`. It gives an address like `aws_db_instance.main["main"]`, which is uglier and no safer.

**Toggle expressions:**

```hcl
locals {
  # HTTPS termination only exists when the consumer supplies an ACM certificate.
  https_enabled = var.load_balancer.certificate_arn != null
  # The whole database tier is opt-in through the presence of the database object.
  database_enabled = var.database != null
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0
  ...
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.application.arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}
```

Using one listener with a switching action, rather than two count-toggled HTTP listeners, keeps the resource address stable. Adding a certificate later becomes an in-place update of `aws_lb_listener.http` and not a destroy/create on port 80. That matters because two listeners on the same port cannot coexist, so the create would fail if it ran before the destroy. `dynamic` is justified here because the nested-block count is input-driven (§2.5).

**RDS tier.** All five resources use the same `local.database_enabled` count. Cross-references inside the tier use `[0]`, which is safe because every resource shares the same count:

```hcl
db_subnet_group_name   = aws_db_subnet_group.database[0].name
vpc_security_group_ids = [aws_security_group.database[0].id]
```

The app→db egress rule lives on the **app** SG, which always exists, but it must still carry `count = local.database_enabled ? 1 : 0`. It references `aws_security_group.database[0].id`, so without the count it would error when the DB is off.

**Outputs.** The constitution §2.4 mandates `try()`:

```hcl
output "db_instance_endpoint" {
  value = try(aws_db_instance.database[0].endpoint, null)
}
output "db_master_user_secret_arn" {
  value = try(aws_db_instance.database[0].master_user_secret[0].secret_arn, null)
}
```

`one(aws_security_group.database[*].id)` also works and fails loudly if count ever goes above 1. Both were verified to return `null` when count = 0 and "known after apply" when count = 1 **[verified]**. Use `try(...[0]..., null)` for consistency with the constitution. `master_user_secret` is a computed list block, so it needs the extra `[0]` inside `try`.

---

### 2. Validation rules (one `validation` block per rule)

Terraform 1.9+ lets a validation condition reference other variables, and this was verified on 1.15.2 (`var.max_size >= var.min_size` inside `max_size`'s validation fired correctly with `expect_failures = [var.max_size]`) **[verified]**. Set `required_version = "~> 1.9"` or higher in `versions.tf`. The constitution says to raise the minor to what features need.

**Null-safe pattern.** `var.database == null || <rule on var.database.x>` works. The `||` short-circuits, so a null object does not error **[verified]**.

**Anti-pattern:** `try(can(regex(..., var.database.engine_version)), true)`. It returns **false** when `database` is null, because `can()` swallows the null-attribute error and returns false, so `try` never falls back. This failed the default run in testing **[verified]**. Always guard with `var.database == null ||`.

**Why module-level validation matters even though the provider validates.** Under a mock provider the AWS provider's own schema validators still run: TG `name` > 32 chars, `name_prefix` > 6 chars, `password` + `manage_master_user_password` conflict, SG rule attribute combinations **[verified]**. But they surface as a resource error. Such an error cannot be targeted with `expect_failures = [var.x]`, gives a worse message, and **causes every later run block in the same file to be skipped** **[verified]**. Catch these at the variable instead.

| # | Variable path | Condition (sketch) | Source of limit |
|---|---------------|--------------------|-----------------|
| 1 | `name` (drives ALB/TG names) | `length(var.name) <= 32` when used verbatim. Reduce the max to leave room for any suffix, e.g. `-tg`, so `<= 29` | ALB and TG names max 32 chars, alphanumeric and hyphens, must not start or end with a hyphen (provider validator and ELB API) |
| 2 | `name` | `can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.name))` | ELB naming rules. ALB names also must not start with `internal-` |
| 3 | `health_check.path` | `startswith(var.<tg>.health_check.path, "/")` | ELB health check path must begin with `/` |
| 4 | `health_check.path` | `length(...) <= 1024` (optional) | ELB API |
| 5 | subnet inputs for ALB (public) | `length(var.vpc.public_subnet_ids) >= 2` | ALB requires subnets in at least 2 AZs |
| 6 | subnet inputs for DB | `var.database == null \|\| length(var.database.subnet_ids /* or vpc.database_subnet_ids */) >= 2` | A DB subnet group must span at least 2 AZs, **even for single-AZ instances** |
| 7 | subnet inputs for app | `length(var.vpc.app_subnet_ids) >= 1` (≥2 recommended for HA; decide in design) | ASG `vpc_zone_identifier` |
| 8 | `app.port` / TG port | `var.x.port >= 1 && var.x.port <= 65535` | TCP |
| 9 | `database.port` | `var.database == null \|\| (port >= 1150 && port <= 65535)` | RDS PostgreSQL port range is 1150–65535 |
| 10 | `database.engine_version` | `var.database == null \|\| can(regex("^[0-9]+(\\.[0-9]+)?$", var.database.engine_version))` | Postgres versions are `16` or `16.4`. A major-only value is allowed and resolves via `auto_minor_version_upgrade`, and the real version shows up in `engine_version_actual` |
| 11 | `database.instance_class` | `var.database == null \|\| startswith(var.database.instance_class, "db.")` | RDS instance class format |
| 12 | `database.backup_retention_period` | `var.database == null \|\| (v >= 1 && v <= 35)`. Use 1, not 0, so backups cannot be disabled (secure default). Use 0 as the minimum only if the design allows disabling | Provider: 0–35 |
| 13 | `database.allocated_storage` | `>= 20 && <= 65536` (gp3 postgres) | RDS storage limits |
| 14 | `database.max_allocated_storage` (if exposed) | `== 0 \|\| >= allocated_storage` (cross-field on the object) | Provider doc |
| 15 | `database.final_snapshot_identifier` / `skip_final_snapshot` | `var.database == null \|\| var.database.skip_final_snapshot \|\| var.database.final_snapshot_identifier != null`. Alternatively derive the identifier in a local and skip this rule (see §5) | Provider: required when `skip_final_snapshot = false` |
| 16 | `asg.min_size`/`max_size` | `max_size >= min_size` (cross-field on the object, or cross-variable) | ASG API |
| 17 | `asg.desired_capacity` (if exposed) | `desired == null \|\| (desired >= min && desired <= max)` | ASG API |
| 18 | `load_balancer.certificate_arn` | `cert == null \|\| can(regex("^arn:aws[a-zA-Z-]*:acm:", cert))` | Format check only. Status cannot be looked up by ARN (see §3) |
| 19 | `app.instance_type` vs AMI | Not a validation. It needs data, so it goes in `check.tf` | |
| 20 | `database.multi_az` | Bool, so no range. If multi_az is true, rule 6 (≥2 subnets) already covers the AZ requirement | |

The constitution says cross-field rules on one object go on the object's validation block. Cross-**variable** rules, such as DB subnets vs `vpc` or ASG vs ALB, go on the variable that is "wrong", and this needs Terraform ≥ 1.9.

**Boundary pairs to test** (constitution §5.1 requires accept + reject): name length 32 (or the computed max) accept / 33 reject. Subnets 2 accept / 1 reject. Backup retention 1 and 35 accept / 0 and 36 reject. Port 1 and 65535 accept / 0 and 65536 reject. DB port 1150 accept / 1149 reject. Engine version `16` and `16.4` accept / `v16` and `sixteen` reject. Instance class `db.t4g.micro` accept / `t4g.micro` reject. Health check path `/` accept / `health` reject.

---

### 3. check.tf (data-source-backed assertions)

Check block failures are **warnings** in real plan/apply but **errors in `terraform test`** unless listed in `expect_failures` **[verified]**. Nested (scoped) data sources inside `check` blocks **do not support `count`/`for_each`** (`The "count" and "for_each" meta-arguments are not supported within nested data blocks.`) **[verified]**. Design the checks around single lookups.

Recommended checks, and keep it to these:

1. **`check "subnets_in_vpc"`**: one scoped `data "aws_subnets"` with `filter { name = "vpc-id", values = [var.vpc.id] }`. Assert `length(setsubtract(local.all_subnet_ids, data.aws_subnets.in_vpc.ids)) == 0`. This covers ALB, app and DB subnets with one API call and no for_each. Verified under mock, including a negative case via `override_data` + `expect_failures = [check.subnets_in_vpc]` **[verified]**.
   - Optionally also assert that the ALB subnets span ≥2 distinct AZs. That needs per-subnet `availability_zone`, and with no for_each in scoped data it would need a top-level `data "aws_subnet"` with `for_each`. A top-level data failure is a hard error, not a warning. **Recommendation: skip it.** The ≥2-subnets validation plus the ALB API error at apply is enough.
2. **`check "ami_architecture"`**: scoped `data "aws_ec2_instance_type" "app"` (`instance_type = var.app.instance_type`). Assert `contains(data.aws_ec2_instance_type.app.supported_architectures, data.aws_ami.selected.architecture)`. `data.aws_ami.selected` is top-level in `main.tf` (constitution §3.2 AMI sourcing) and is referenced from the check. This catches the classic graviton `t4g` + `x86_64` AMI mismatch, which otherwise fails only when the ASG launches instances, i.e. asynchronously after apply "succeeds".
3. **Certificate status: do NOT implement.** In AWS provider 5.x, `data "aws_acm_certificate"` looks up only by `domain`/`tags`/`statuses` and has **no `arn` argument**, so an ARN input cannot be checked for `ISSUED`. Use the ARN format validation (rule 18). The listener create fails fast at apply if the cert is invalid.
4. Optional, and low value: DB engine version availability via `data "aws_rds_engine_version"`. Skip it. RDS rejects bad versions quickly at apply.

---

### 4. terraform test with `mock_provider "aws"` and `command = plan`

**What is known vs unknown at plan under mocks [verified]:**

| Value | At plan with mock | Implication |
|-------|-------------------|-------------|
| Data source attributes (`data.aws_ami.selected.id`, `.architecture`, `aws_subnets.ids`, `aws_iam_policy_document.json`) | **Known**, filled with *random 8-char strings* unless mocked | Must `mock_data` anything that is validated, compared, or used in check blocks |
| Resource computed attrs (`arn`, `id`, `dns_name`, `endpoint`, `name` when `name_prefix` is used, `master_user_secret`) | **Unknown** | Assertions on them fail with "Unknown condition value" **[verified]** |
| Configured arguments (`port`, `protocol`, `ssl_policy`, `storage_encrypted`, `default_action[0].type`, `metadata_options[0].http_tokens`) | Known | Assert freely |
| `length(resource)` / `length(resource) == 0` for count-toggled resources | Known | Primary way to assert toggles |
| Outputs from `try(x[0].attr, null)` when count = 0 | Known `null` | `output.x == null` assertable **[verified]** |

**Required mocks (file-level `mock_provider "aws"` block):**

```hcl
mock_provider "aws" {
  # Random-string policy JSON fails the provider's JSON validator on aws_iam_role.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_ami" {
    defaults = {
      id           = "ami-0123456789abcdef0"
      architecture = "arm64"
    }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["arm64"]
    }
  }
  mock_data "aws_subnets" {
    defaults = {
      ids = [/* every subnet ID used in the file's variables {} block */]
    }
  }
}
```

- **`aws_iam_policy_document` is mandatory.** Without it the plan fails with `"assume_role_policy" contains an invalid JSON policy: not a JSON object` **[verified]**. The alternative is `jsonencode()` literals in the module, which avoids the data source entirely.
- **`aws_ami` must be mocked** so `image_id` is realistic and the architecture check passes. The random id itself is accepted by the launch template.
- **`aws_subnets.ids` must contain every test subnet ID**, or `check.subnets_in_vpc` fails every run.
- `data "aws_region"`/`aws_caller_identity`, if used to build ARNs or names, also need `mock_data` with realistic values (e.g. `name = "us-east-1"`, `account_id = "123456789012"`).

**Comparing unknowns.** When an assertion must prove wiring, e.g. that the HTTPS listener forwards to our target group or that the app→db rule references the DB SG, use a per-run `override_resource` with `override_during = plan` **[verified]**:

```hcl
run "https_forwards_to_target_group" {
  command = plan
  variables { load_balancer = { certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc" } }

  override_resource {
    target          = aws_lb_target_group.application
    override_during = plan
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/0123456789abcdef"
    }
  }

  assert {
    condition     = aws_lb_listener.https[0].default_action[0].target_group_arn == aws_lb_target_group.application.arn
    error_message = "HTTPS listener must forward to the application target group."
  }
}
```

The same pattern applies to `aws_security_group.database` `id` (for `referenced_security_group_id` assertions) and `aws_security_group.application` `id`. Otherwise mark the assertion `[plan-unknown]` in design.md and move it to the acceptance tests.

**Asserting count-toggled resources:**

- Off: `length(aws_db_instance.database) == 0`, `length(aws_lb_listener.https) == 0`, `output.db_instance_endpoint == null`.
- On: `length(aws_db_instance.database) == 1`, then `aws_db_instance.database[0].storage_encrypted == true`. Only index `[0]` in runs where count is known to be 1, because indexing an empty tuple errors the run.
- HTTP listener switch: `aws_lb_listener.http.default_action[0].type == "redirect"` and `aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"` with a cert. `default_action[0].type == "forward"` and `length(aws_lb_listener.http.default_action[0].redirect) == 0` without one. `default_action` and `redirect` are list blocks in aws_lb_listener, so `[0]` indexing is valid.

**Validation tests.** `expect_failures = [var.database]` (or `[var.name]`, etc.) per run. After a validation `expect_failures` run, later runs execute normally **[verified]**. But a run that ends in an *unexpected* error (provider validator, unknown condition, unmocked check failure) marks every later run in that file `skip` **[verified]**. That is a strong reason to keep `unit_validation.tftest.hcl` separate (constitution §5.3) and to catch limits at the variable level.

**Check-block negative tests:** use `override_data { target = data.aws_ami.selected, values = { architecture = "x86_64" } }` plus `expect_failures = [check.ami_architecture]` **[verified pattern with the subnets check]**.

**Existing `tests/validate.tftest.hcl`** is a placeholder (`run "validate" {}` against an empty root with `required_providers {}`). Replace it with the four constitution files (`unit_basic`, `unit_complete`, `unit_edge_cases`, `unit_validation`) plus `acceptance` and `integration`. A `run {}` with no `command` defaults to **apply**, which with a real provider would try to create resources. Every unit run must say `command = plan`.

**Suggested edge-case runs (`unit_edge_cases.tftest.hcl`):**

1. No cert, no DB (minimal): no HTTPS listener, HTTP forwards, zero RDS resources, no app→db egress rule, DB outputs null.
2. Cert, no DB: HTTPS listener exists with a TLS 1.3 policy, HTTP redirects, DB tier absent.
3. DB, no cert: DB tier count = 1 for all five resources, HTTP forwards.
4. DB with `multi_az = true` and 2 subnets: accepted, `aws_db_subnet_group.database[0].subnet_ids` has length 2.
5. DB with `skip_final_snapshot = false`: `final_snapshot_identifier != null` (derived).
6. `deletion_protection` default true in the module and overridden false: both plan.

---

### 5. Gotchas and failure modes

| Gotcha | Behaviour | Mitigation |
|--------|-----------|------------|
| **Target group replacement** | Changing `port`, `protocol`, `vpc_id`, or `target_type` forces a new TG. With a fixed `name` the create collides with the existing TG (`DuplicateTargetGroupName`), and if you add `create_before_destroy` the listener is left pointing at a TG being deleted (`ResourceInUse`). | Use `name_prefix` (**max 6 chars**, and the provider errors at plan if longer **[verified]**) plus `lifecycle { create_before_destroy = true }`. Validate the derived prefix: `substr(var.name, 0, 6)` or a dedicated ≤6 input. The TG `name` output then comes from the resource (unknown at plan). |
| **Launch template `user_data`** | Must be base64. The provider does **not** reject raw text at plan, and a mock plan with raw `#!/bin/bash` passed **[verified]**. It fails or misbehaves only at apply or launch. | Always `user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {...}))`. Add a unit assertion: `can(base64decode(aws_launch_template.application.user_data))`. |
| **Launch template + running instances** | Constitution §2.5 requires `create_before_destroy` on launch templates and SGs. | Use `name_prefix`, `create_before_destroy = true`, and in the ASG `launch_template { id = ..., version = aws_launch_template.application.latest_version }` plus an `instance_refresh` block so template changes roll instances. |
| **ASG `desired_capacity` drift** | Autoscaling policies change desired capacity, and if the module sets `desired_capacity` the next plan reverts it. | Either don't set `desired_capacity` (it is Optional+Computed, so no drift) or set it and add `lifecycle { ignore_changes = [desired_capacity] }`. `ignore_changes` cannot be conditional. Prefer not exposing it, or exposing it as initial-only with ignore_changes. |
| **ASG + TG attachment** | Setting `target_group_arns` on `aws_autoscaling_group` *and* using `aws_autoscaling_traffic_source_attachment`/`aws_autoscaling_attachment` causes perpetual diffs. | Use only the ASG `target_group_arns` argument. |
| **RDS `final_snapshot_identifier`** | Required when `skip_final_snapshot = false` (the provider default). It is **not** caught at plan, since a mock plan with neither set passed **[verified]**. It fails at **destroy** (`final_snapshot_identifier is required when skip_final_snapshot is false`), leaving a stuck teardown. | Default `skip_final_snapshot = false` (secure) and derive `final_snapshot_identifier = "${var.name}-final"` in a local. It must start with a letter and contain no `--` or trailing hyphen, which the name regex already covers. Note it is static: a second destroy/recreate cycle collides with the existing snapshot name (`DBSnapshotAlreadyExists`), so examples set `skip_final_snapshot = true`. |
| **`deletion_protection` blocks destroy** | With `deletion_protection = true` on `aws_db_instance` (and `enable_deletion_protection` on `aws_lb`), `terraform destroy` fails. The constitution §4.3 requires examples to deploy **and destroy** cleanly. | Module default `true` (secure). Examples and the integration test set `deletion_protection = false`, `skip_final_snapshot = true`, and ALB `deletion_protection = false`. Document the two-step destroy for production (flip to false, apply, destroy). |
| **`manage_master_user_password` vs `password`** | They conflict. The provider errors at plan even under mock **[verified]**. | Hardcode `manage_master_user_password = true` and don't expose `password`/`password_wo`. Output `master_user_secret[0].secret_arn` through `try()`. Optionally expose `master_user_secret_kms_key_id`. |
| **SG rule with a referenced SG** | `aws_vpc_security_group_egress_rule`/`ingress_rule` accept exactly one of `cidr_ipv4`, `cidr_ipv6`, `prefix_list_id`, `referenced_security_group_id`. Setting two gives `Invalid Attribute Combination` at plan **[verified]**. | App→DB egress: `security_group_id = app SG`, `referenced_security_group_id = db SG`, `ip_protocol = "tcp"`, `from_port = to_port = db port`. DB ingress: the mirror image. Both are count-toggled with the DB tier. Don't mix these with inline `ingress`/`egress` blocks on `aws_security_group`, because they fight each other. |
| **SG egress default** | `aws_security_group` created by Terraform has **no** default allow-all egress, because Terraform removes it. | Every required egress (app→db, app→443 for SSM/package repos, ALB→app) must be an explicit rule. |
| **SG replacement** | Renaming an SG forces replacement, and deletion hangs while ENIs (RDS, instances) still reference it. | `name_prefix` + `create_before_destroy = true` (constitution §2.5). |
| **multi_az + DB subnet group** | Multi-AZ requires the subnet group to cover ≥2 AZs. So does *any* subnet group, even for single-AZ instances. Two subnets in the same AZ pass the count validation but fail at apply (`DBSubnetGroupDoesNotCoverEnoughAZs`). | Count validation (rule 6). Documented as an apply-time failure if both subnets share an AZ. Optional AZ check via top-level data (see §3, recommended skip). |
| **ALB subnets in the same AZ** | Same issue: `aws_lb` needs ≥2 subnets in distinct AZs, otherwise `ValidationError: At least two subnets in two different Availability Zones must be specified`. | Rule 5, and documented. |
| **HTTPS listener `ssl_policy`** | Leaving it unset gives the older default `ELBSecurityPolicy-2016-08` (TLS 1.0+). | Default `ELBSecurityPolicy-TLS13-1-2-2021-06`. Assert it in unit_complete. |
| **Adding a certificate later** | With separate HTTP listener resources per mode, Terraform may create the new port-80 listener before destroying the old one → `DuplicateListener`. | Single `aws_lb_listener.http` with a switching `default_action` (see §1). |
| **engine_version drift** | A full `16.4` with `auto_minor_version_upgrade = true` shows a diff after AWS upgrades the minor. | Recommend major-only (`16`) as the default. The provider matches the prefix. Output `engine_version_actual`. |
| **RDS `identifier`** | A fixed identifier plus a replacement-forcing change (e.g. `storage_encrypted`, `kms_key_id`) collides. | Accept it: replacement of a DB is rare and should be deliberate. Using `identifier_prefix` makes names non-idempotent, which the constitution §2.2 discourages. |

---

### Rationale

- The count-toggle and `try()` output patterns are directly required by the module constitution §2.4/§2.5 and were confirmed to plan cleanly under mocks in both the 0 and 1 states.
- Provider docs (hashicorp/aws 5.100.0, `aws_db_instance`) confirm: `final_snapshot_identifier` "Must be provided if `skip_final_snapshot` is set to `false`". `manage_master_user_password` "Cannot be set if `password` or `password_wo` is provided". `backup_retention_period` "Must be between 0 and 35". `master_user_secret` is a computed block available only when managed passwords are on. `deletion_protection` means the "database can't be deleted".
- Provider docs for `data.aws_acm_certificate` (5.100.0) show only `domain`, `key_types`, `statuses`, `types`, `most_recent`, `tags`. There is no ARN lookup, so a certificate-status check against an ARN input is not implementable.
- Local experiments on Terraform 1.15.2 established the mock-provider behaviours: random strings for data sources, unknowns for computed resource attrs, provider validators still running, check blocks failing tests, later runs skipped after an unexpected error, `override_during = plan`, cross-variable validation, `||` short-circuit on null, and no `for_each` in scoped check data.

### Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| `for_each = var.database == null ? {} : { main = var.database }` for the RDS tier | Constitution reserves `for_each` for fan-out. It produces keyed addresses for a singleton with no benefit. |
| Two HTTP listeners (`http_redirect`, `http_forward`) each count-toggled | Address changes when a cert is added, with a create-before-destroy race on port 80 (`DuplicateListener`). |
| Relying on provider validators instead of variable validations | Errors can't be targeted by `expect_failures`, they skip later test runs in the file, and the messages don't name the module input. |
| `try(can(regex(..., var.database.x)), true)` for null-safe validation | Returns false on a null object. `var.database == null \|\| ...` is correct **[verified]**. |
| Certificate status check via `data.aws_acm_certificate` | No ARN argument in provider 5.x. Would need the domain as a second input. |
| Per-subnet AZ checks via scoped `data "aws_subnet"` | Nested data blocks in `check` don't support `for_each` **[verified]**. A top-level data source makes failures hard errors. |
| Asserting ARNs or IDs in unit tests without overrides | Unknown at plan, so the test fails with "Unknown condition value" **[verified]**. |
| Fixed TG `name` | Replacement collides. `name_prefix` + `create_before_destroy` is the standard fix. |
| Exposing `password` | Stored in state in plaintext, and it conflicts with managed passwords. |

### Sources

- Module constitution: `/workspace/.foundations/memory/module-constitution.md` §1.3, §2.3–2.5, §3.2, §4.3, §5.1, §5.3
- Existing placeholder test: `/workspace/tests/validate.tftest.hcl`
- Provider docs hashicorp/aws 5.100.0: `aws_db_instance` (doc 9210866), `aws_lb_target_group` (doc 9211300), data `aws_acm_certificate` (doc 9209887)
- AWS ELB: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html (≥2 AZ subnets, naming), https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html (TLS security policies)
- AWS RDS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.WorkingWithRDSInstanceinaVPC.html (DB subnet group ≥2 AZs), https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html
- Terraform test docs: https://developer.hashicorp.com/terraform/language/tests/mocking (mock_provider, mock_data, override_resource, override_during), https://developer.hashicorp.com/terraform/language/checks
- Local experiments (Terraform v1.15.2, aws ~> 5.0) in the session scratchpad, reproduced in the **[verified]** notes above

# Module Design: terraform-aws-three-tier-app

**Branch**: 003-three-tier-app
**Issue**: #3
**Date**: 2026-09-26
**Status**: Draft
**Provider**: hashicorp/aws `~> 5.0` (resolves to 5.100.0, the final 5.x release)
**Terraform**: `~> 1.14`

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Resources & Architecture](#2-resources--architecture)
3. [Interface Contract](#3-interface-contract)
4. [Security Controls](#4-security-controls)
5. [Test Scenarios](#5-test-scenarios)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

This module provisions the infrastructure for any three-tier web application inside a VPC that already exists. It creates three tiers:

- **Web tier**: a public entry point that accepts client traffic from the internet.
- **App tier**: a self-healing, horizontally scaled fleet of private application servers.
- **Data tier**: an optional managed PostgreSQL database that only the app tier can reach.

Application teams in the craigsloggett-lab organisation consume the module, usually straight after the organisation's `vpc` module, whose outputs it accepts unchanged. It gives every team the same secure, repeatable baseline, so no team has to rebuild tier isolation, encryption, credential handling and rolling instance replacement for each application.

**Scope boundary**: The following are out of scope:

- Creating or changing networking (VPC, subnets, routes, NAT, VPC endpoints).
- Creating KMS keys, certificates or DNS records.
- Deploying application code beyond passing through a boot script.
- Autoscaling policies, WAF, CDN and caching tiers.
- Read replicas, Aurora and database parameter tuning.
- Log archive destinations.

The module accepts references to externally managed keys, certificates and IAM policies. It never creates them.

### Requirements

**Functional requirements**:

- FR-01: The module MUST deploy into a caller-supplied VPC. It takes the VPC ID and the public, private and database subnet ID maps exactly as the organisation's `vpc` module outputs them. It MUST NOT create any networking.
- FR-02: The web tier MUST be reachable from the internet. It MUST be placed only in the public subnets and span at least two of them.
- FR-03: When the caller supplies a TLS certificate, the web tier MUST serve HTTPS and MUST permanently redirect every plain-HTTP request to HTTPS. When no certificate is supplied, the web tier MUST serve plain HTTP only.
- FR-04: The web tier MUST forward traffic to the app tier on a single configurable application port, and MUST judge app-server health with a configurable HTTP health-check path.
- FR-05: The app tier MUST run in the private subnets only, as a fleet with configurable minimum and maximum size. The fleet MUST replace servers that fail the web tier's health check.
- FR-06: A change to the server definition (image, size, boot script, and so on) MUST roll through the fleet automatically, with no manual replacement.
- FR-07: The app-server image MUST be selected at plan time from a caller-controlled owner list and name pattern. Image IDs are never typed in by hand.
- FR-08: App servers MUST receive their cloud credentials only through an attached role. Callers choose which managed permission sets the role carries. The default grants remote shell access through Session Manager only, with no SSH.
- FR-09: The caller's boot script MUST be passed to app servers unchanged.
- FR-10: The data tier MUST be optional and all-or-nothing. Supplying a database configuration creates it, and omitting that configuration creates nothing in the data tier.
- FR-11: When present, the data tier MUST be a single PostgreSQL database placed only in the database subnets. Its administrator password MUST be generated and stored by the cloud provider's secrets service and never appear in Terraform configuration or state. The module MUST expose the secret's identifier so callers can grant read access to it.
- FR-12: Network reachability MUST follow the tier chain:
  - The internet reaches only the web tier's listener ports.
  - The web tier reaches only the app tier's application port.
  - Only the app tier reaches the database port.
  - The app tier can reach HTTPS endpoints for cloud APIs and package repositories.
  - The data tier has no outbound access.
- FR-13: Every created resource MUST carry a `Name` tag taken from its subsystem's configured name, merged over the caller's tags.
- FR-14: Callers MAY supply their own encryption keys for app-server disks, database storage and the database secret. When no key is supplied, the provider-managed default keys MUST be used.
- FR-15: Invalid inputs MUST be rejected at plan time, with an error message that names the offending input path.

**Non-functional requirements**:

- NFR-01 (compatibility): The module MUST work with AWS provider 5.x and MUST NOT use syntax that exists only in 6.x. The 6.x upgrade is a separate, scheduled change that will ship as a major module release.
- NFR-02 (availability): By default, the web tier, the app fleet and the database MUST each span at least two Availability Zones. The database defaults to a synchronous standby, 7-day backups and deletion protection.
- NFR-03 (security baseline):
  - Encryption at rest MUST be on for every disk and database, with no way to turn it off.
  - App servers MUST require token-based instance metadata (IMDSv2) and MUST NOT receive public IPs.
  - The database MUST never be publicly accessible.
  - HTTPS MUST use TLS 1.2 or later.
- NFR-04 (operability): Resources that running infrastructure references (security groups, the server template, the target group) MUST be replaced without downtime. The module MUST plan cleanly in a test harness with mocked providers and no cloud credentials.
- NFR-05 (compliance traceability): Every AWS Security Hub FSBP control this design leaves unmet MUST be listed with a reason. Every Trivy Critical or High finding MUST be either fixed or suppressed inline with a written justification (constitution §5.2).
- NFR-06 (cost): Defaults target small, cost-effective sizes (constitution §7.1). Production callers scale up through inputs.

---

## 2. Resources & Architecture

### Architectural Decisions

**Native resources, no child modules**: Every resource is authored natively and grouped one file per AWS service (constitution §1.1, §2.1).
*Rationale*: Every current terraform-aws-modules release needs AWS provider 6.x (alb 10.5.1 needs `>= 6.28`, autoscaling 9.3.2 needs `>= 6.56`, rds 7.2.2 needs `>= 6.28`), so none of them can be called under `~> 5.0`. They also bring `this` naming and `create_*` booleans, both of which the constitution forbids.
*Source*: research-registry-patterns.md §2.
*Rejected*: Calling public modules, because they are incompatible with provider 5.x.

**Provider `~> 5.0`; example pins `5.100.0`**: `versions.tf` declares `hashicorp/aws` `~> 5.0`. The runnable example pins exactly `5.100.0`.
*Rationale*: This is a user requirement. The fleet is standardised on 5.x, and 5.100.0 is the last 5.x release. The following 6.x-only syntax is never used:
- the per-resource `region` argument
- `aws_lb` `health_check_logs`
- `aws_lb_listener` `jwt_validation`/`timeouts`
- `aws_lb_target_group` `target_control_port`
- `aws_autoscaling_group` `instance_lifecycle_policy`/`timeouts.update`
- `aws_db_instance` `upgrade_rollout_order`/`warning_event_categories`
- `data.aws_ami` `allow_unsafe_filter`

The following are also never used:
- `aws_launch_template` `elastic_gpu_specifications`/`elastic_inference_accelerator`, which were removed in 6.x.
- `aws_iam_role` `inline_policy`/`managed_policy_arns`, which are deprecated.

Nullable-bool arguments get real booleans, and `data.aws_ami` always sets `owners`. This keeps the later 6.x migration small.
*Source*: research-provider-resources.md, "Consolidated 5.x vs 6.x compatibility checklist" (Registry versions API; Version 6 Upgrade Guide doc 13746811).
*Rejected*: `~> 6.0`, because the user explicitly deferred the 6.x upgrade.

**Terraform `~> 1.14`**: `required_version = "~> 1.14"`.
*Rationale*: The module's own features need at least 1.11:
- Cross-variable validation (the `database` rule that reads `var.vpc`) needs 1.9 or later.
- The unit-test harness relies on `override_resource`/`override_data` with `override_during = plan`, which needs 1.11 or later.

The org `vpc` module (`craigsloggett-lab/vpc/aws` 0.1.0), which is this module's input source, already requires Terraform 1.14 or later. Every consumer therefore already runs 1.14+, and one floor across the org's modules costs nothing. Constitution §4.1 prescribes raising the minor to what features need (`~> 1.14` is its own example). The design's test behaviour was verified locally on Terraform 1.15.2 with aws 5.100.0.
*Source*: research-edge-cases.md §2 (cross-variable validation [verified]), research-registry-patterns.md §1 (vpc module pins `>= 1.14`).
*Rejected*: `~> 1.9`, which is enough for validation but not for the test harness, and is lower than every consumer's actual floor.

**`vpc` input accepts the org vpc module's outputs unchanged**: The subnet fields are `map(string)` keyed by subnet short name (for example `web-a`), not by AZ. Resources receive `values(...)`.
*Rationale*: The vpc module's `outputs.tf` emits `{ for k, s in aws_subnet.<tier> : k => s.id }`. Keys come from literal input maps, so they are known at plan. `database_subnet_ids` is optional (default `{}`), because the vpc module returns `{}` for an empty tier.
*Source*: research-registry-patterns.md §1.
*Rejected*: `list(string)`, because it forces `values()` onto callers. Re-keying by AZ, because it needs apply-time data.

**Presence-of-value toggles, `count` 0/1 only**: HTTPS is toggled by `web.certificate_arn != null`, and the data tier by `database != null`. Each conditional singleton uses `count = local.<toggle> ? 1 : 0`. The only `for_each` is the IAM policy attachment fan-out.
*Rationale*: Constitution §1.1 and §2.5 require this. Every cross-reference inside the data tier uses `[0]`, which is safe because all five data-tier resources share one count. The `app_to_database` rule lives on the always-present app security group but carries the same count, because it references `aws_security_group.database[0]`.
*Source*: research-edge-cases.md §1.
*Rejected*: `for_each = var.database == null ? {} : { main = ... }`, which adds keyed addresses for a singleton. `enable_database` booleans, which break constitution §1.1.

**One always-present HTTP listener with a switching `default_action`**: `aws_lb_listener.http` is always created on port 80.
- Its `default_action.type` is `redirect` when HTTPS is enabled and `forward` otherwise.
- A `dynamic "redirect"` block (0/1, input-driven, so constitution §2.5 permits it) sends `HTTP_301` to `HTTPS:443`.
- `target_group_arn` is set only when forwarding.

`aws_lb_listener.https` is `count`-toggled.
*Rationale*: Adding or removing a certificate becomes an in-place update of one listener. Two port-80 resources toggled against each other would race on create and destroy and fail with `DuplicateListener`.
*Source*: research-edge-cases.md §1 and §5 ("Adding a certificate later"); research-registry-patterns.md §3.
*Rejected*: Separate `http_redirect`/`http_forward` listeners, as proposed in research-provider-resources.md §2, which the later edge-case research superseded.

**TLS policy default `ELBSecurityPolicy-TLS13-1-2-2021-06`, validated against an allowlist**: The HTTPS listener always sets `ssl_policy`. The allowlist holds TLS 1.2+/1.3 standard, restricted, TLS 1.3-only and FIPS variants.
*Rationale*: The provider default `ELBSecurityPolicy-2016-08` allows TLS 1.0/1.1 and fails ELB.17. Setting the policy is required for correctness. It is not optional hardening. The chosen default is the AWS-recommended console default and supports TLS 1.2 clients.
*Source*: research-aws-best-practices.md §1; research-provider-resources.md §2.
*Rejected*: The provider default. `TLS13-1-3-2021-06` as the default, because it breaks TLS 1.2 clients (it stays allowed). `Ext*` and legacy policies.

**Replacement-safe naming**: The security groups and launch template use `name_prefix = "<object name>-"`, and the target group uses `name_prefix = substr(var.app.name, 0, 6)`. All four set `lifecycle { create_before_destroy = true }`. *Implementation note*: the provider rejects a launch template `name_prefix` shorter than 3 characters, and validation allows a 1-character `app.name`. So `ec2.tf` uses `"${var.app.name}-lt-"` when `app.name` is a single character, and `"${var.app.name}-"` otherwise. The ALB, ASG, IAM role, instance profile, DB subnet group and DB instance use the object `name` verbatim.
*Rationale*: Constitution §2.5 requires `create_before_destroy` on security groups, launch templates and anything a running instance references. The target group is ForceNew on `port`/`protocol`/`vpc_id`. With a fixed name, a replacement collides (`DuplicateTargetGroupName`), and without CBD the listener blocks the destroy (`ResourceInUse`). AWS caps the TG `name_prefix` at 6 characters. Random suffixes are functionally required here, which is the exception constitution §2.2 allows. `Name` tags still come from the object's `name`.
*Source*: research-edge-cases.md §5 (target group, SG replacement rows; 6-char limit [verified]); research-provider-resources.md §3 and §10.
*Rejected*: Fixed TG name, which breaks `app.port` changes. `identifier_prefix` on RDS, because DB replacement should be deliberate and names should stay idempotent.

**ASG coupling**:
- `launch_template { id, version = aws_launch_template.app.latest_version }`.
- `instance_refresh { strategy = "Rolling", preferences { min_healthy_percentage = 90 } }`.
- Inline `target_group_arns`.
- `health_check_type = "ELB"` with a configurable grace period.
- `desired_capacity` is not set.

*Rationale*: `$Latest` never triggers an instance refresh, while `latest_version` makes each new template version a planned ASG diff that rolls the fleet (FR-06). Inline `target_group_arns` is the single attachment mechanism, and mixing it with `aws_autoscaling_traffic_source_attachment` causes perpetual diffs. `desired_capacity` is Optional+Computed. Leaving it unset means AWS starts at `min_size`, and scaling policies that callers attach later do not cause drift, so no `ignore_changes` is needed.
*Source*: research-provider-resources.md §5; research-registry-patterns.md §2 (autoscaling 9.3.2 coupling); research-edge-cases.md §5.
*Rejected*: `$Latest`. A traffic-source attachment resource. Exposing `desired_capacity`, which would need `ignore_changes` to avoid fighting scaling policies.

**Launch template**:
- `metadata_options`: `http_endpoint = "enabled"`, `http_tokens = "required"`, `http_put_response_hop_limit = 1`.
- A `network_interfaces` block with `associate_public_ip_address = false`, `delete_on_termination = true` and `security_groups = [app]`. `vpc_security_group_ids` is not used, because the two conflict.
- One `block_device_mappings` entry on `data.aws_ami.selected.root_device_name`: gp3, `encrypted = true`, optional CMK, `delete_on_termination = true`.
- `user_data = base64encode(var.app.user_data)` when set.
- `update_default_version = true`.
- `tag_specifications` for `volume` only.

*Rationale*: IMDSv2 is not the provider default (EC2.8/EC2.170, constitution §3.2). An explicit `false` on the ENI satisfies EC2.25 whatever the subnet setting. The launch template has no `user_data_base64`, and raw text passes plan but fails at launch. ASG `tag` blocks with `propagate_at_launch = true` tag instances, but ASG tags never reach volumes. Provider `default_tags` also do not propagate to ASG-launched resources (provider issue #32328), so volumes need `tag_specifications`.
*Source*: research-provider-resources.md §4; research-aws-best-practices.md §4; research-edge-cases.md §5.
*Rejected*: `vpc_security_group_ids`, because EC2.25 then depends on the subnet setting. Requiring pre-encoded user data. Duplicate instance tagging from both the LT and the ASG.

**AMI selection**: `data "aws_ami" "selected"` in `main.tf` uses `most_recent = true`, `owners = var.ami.owners`, and one `filter { name = "name", values = [var.ami.name_pattern] }`. The defaults are `["amazon"]` and `al2023-ami-2023.*-x86_64`, which match the default `t3.micro`.
*Rationale*: Constitution §3.2 (AMI sourcing) requires this. `most_recent` without `owners` is a hard error in 6.x. A newly published AMI changes the LT and rolls the fleet, which is desirable for patching. Callers who need to freeze the image narrow `name_pattern`.
*Source*: research-provider-resources.md §6.
*Rejected*: SSM `resolve:ssm:` image IDs, which bypass the constitution-mandated owner filter. An `ami_id` override input, which hard-codes image IDs.

**IAM**:
- `aws_iam_role.app` trusts only `ec2.amazonaws.com`, through an inline `jsonencode()` trust policy.
- `aws_iam_instance_profile.app`.
- `aws_iam_role_policy_attachment.app` uses `for_each = var.app.managed_policy_arns`, a `map(string)` keyed by static names. The default is `{ ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }`.
- No inline policies.

*Rationale*: Static map keys avoid `Invalid for_each argument` when a caller passes a policy ARN created in the same apply. `toset(list)` would fail there. `jsonencode()` keeps the trust policy fully known at plan, so unit tests can assert the principal, and it removes a data source that would otherwise need a JSON mock. The deprecated `managed_policy_arns`/`inline_policy` role arguments claim exclusive ownership and fight attachment resources.
*Source*: research-registry-patterns.md §2 (autoscaling `iam_role_policies`) and Alternatives; research-provider-resources.md §7; research-edge-cases.md §4 (mock JSON failure [verified]).
*Rejected*: `set(string)` of ARNs. `data.aws_iam_policy_document` for the trust policy. Role-level `managed_policy_arns`.

**RDS PostgreSQL**:
- Hardcoded secure settings: `storage_encrypted = true`, `publicly_accessible = false`, `manage_master_user_password = true`, `storage_type = "gp3"`, `copy_tags_to_snapshot = true`, `auto_minor_version_upgrade = true`, `iam_database_authentication_enabled = true`.
- Configurable settings with secure defaults: `multi_az = true`, `backup_retention_period = 7`, `deletion_protection = true`, `skip_final_snapshot = false`.
- `final_snapshot_identifier = local.database_final_snapshot_identifier` (`"<database.name>-final"`).

*Rationale*:
- Managed master password: the password never reaches state, RDS rotates it every 7 days (SecretsManager.1/.4), and it conflicts with `password`.
- `final_snapshot_identifier` is required whenever `skip_final_snapshot = false`, and plan does not catch its absence. Destroy would fail, so it is always derived.
- IAM database authentication is free and additive (password auth still works). It satisfies RDS.10.
- `copy_tags_to_snapshot` (RDS.17) and `auto_minor_version_upgrade` (RDS.13) have no legitimate reason to be off in this module.
- The engine version is **major-only and at least 15**. With auto minor upgrades on, a pinned `16.4` produces a downgrade diff once AWS upgrades the minor. PostgreSQL 15+ default parameter groups set `rds.force_ssl = 1`, which enforces TLS to the database without a custom parameter group.
- The default username `app_admin`, with `postgres`/`admin`/`root`/`rdsadmin` rejected, satisfies RDS.25.
- The port defaults to 5432 but is configurable. RDS.23 is accepted: changing the port is obscurity only, and callers who need the control set `database.port`.

*Source*: research-provider-resources.md §8; research-aws-best-practices.md §6 and §7; research-edge-cases.md §2 (rules 9–15) and §5.
*Rejected*: `password`/`password_wo`. A custom parameter group, which is out of scope and made unnecessary by the engine floor. A non-default port as the default, which has low security value and surprises callers. Exposing `storage_encrypted`/`publicly_accessible` toggles (see §7, constitution deviation 2).

**Security group topology (one group per tier, one resource per rule, named `<subject>_<purpose>`)**:

| Rule resource | Group | Direction | Port | Peer |
|---|---|---|---|---|
| `web_http` | web | ingress | 80/tcp | `0.0.0.0/0` |
| `web_https` (count: HTTPS) | web | ingress | 443/tcp | `0.0.0.0/0` |
| `web_to_app` | web | egress | `app.port`/tcp | app SG |
| `app_from_web` | app | ingress | `app.port`/tcp | web SG |
| `app_https` | app | egress | 443/tcp | `0.0.0.0/0` |
| `app_to_database` (count: DB) | app | egress | `database.port`/tcp | database SG |
| `database_from_app` (count: DB) | database | ingress | `database.port`/tcp | app SG |

The database SG has no egress rules. Terraform removes the AWS default allow-all egress, and RDS needs none.
*Rationale*: This is the user's decision (clarification Q2). Tier-to-tier traffic uses `referenced_security_group_id`, per the AWS VPC guidance. Standalone rule resources are the provider's current best practice and avoid the reference cycles that inline rules create. The only `0.0.0.0/0` ingress is on the web listeners (EC2.18 allows 80 and 443).
*Source*: research-aws-best-practices.md §9; research-provider-resources.md §10; research-edge-cases.md §5.
*Rejected*: Inline `ingress`/`egress` blocks or `aws_security_group_rule`. Consumer-supplied rule maps, because the architecture fixes the rules.

**check.tf holds data-backed assertions only**:
- `check "subnets_in_vpc"` uses a scoped `data "aws_subnets" "in_vpc"` filtered on `vpc-id`. It asserts that every supplied subnet ID (all three maps, from `local.check_subnet_ids`) is in the VPC.
- `check "ami_architecture"` uses a scoped `data "aws_ec2_instance_type" "app"`. It asserts that `data.aws_ami.selected.architecture` is in `supported_architectures`.

*Rationale*: Check blocks warn in real plans but fail `terraform test` unless listed in `expect_failures`. Scoped check data cannot use `count`/`for_each` [verified], so each check is a single lookup. The architecture check catches the Graviton/x86 mismatch, which would otherwise fail asynchronously after apply.
*Source*: research-edge-cases.md §3.
*Rejected*: A certificate-status check. `data.aws_acm_certificate` has no `arn` argument in 5.x, so the ARN format is validated instead. Per-subnet AZ checks, which would need a top-level `for_each` data source that turns failures into hard errors.

**Trivy findings handled by inline, justified suppressions**: Five checks fail by design and are suppressed with a justification comment followed by `#trivy:ignore:<ID>` directly above the resource (or, for AWS-0177, the attribute). Both forms were verified to work with Trivy 0.70.0:

| Trivy ID | Resource | Justification |
|---|---|---|
| AWS-0053 (HIGH) | `aws_lb.web` | The module's purpose is an internet-facing web tier (FR-02) |
| AWS-0054 (CRITICAL) | `aws_lb_listener.http` | It forwards plain HTTP only when the caller supplies no certificate (user-directed, FR-03). With a certificate, it only redirects |
| AWS-0104 (CRITICAL) | `aws_vpc_security_group_egress_rule.app_https` | User-directed egress for SSM, Secrets Manager and package repositories on 443 only (clarification Q2) |
| AWS-0052 (HIGH) | `aws_lb.web` | `drop_invalid_header_fields` was not selected by the user. See §7 OQ-1, which should be resolved before release |
| AWS-0177 (MEDIUM) | `aws_db_instance.database` (`deletion_protection`) | False positive for the module: `database.deletion_protection` defaults to `true`. Trivy evaluates the module through `examples/public-https`, which sets it to `false` so the example destroys cleanly. Added in item H because the repo stop hook fails on MEDIUM (`--severity CRITICAL,HIGH,MEDIUM`) |

Every rule resource sets `description`, which clears AWS-0124.
*Source*: local Trivy 0.70.0 scan of a design prototype; constitution §5.2.
*Rejected*: A repository-wide `.trivyignore`, which hides the justification away from the code.

**Tagging**: Every taggable resource sets `tags = merge(var.tags, { Name = var.<object>.name })`, where `<object>` is the subsystem that owns the resource (web, app or database). Because `Name` is merged last, a caller-supplied `Name` never overrides it. The ASG emits the same map through `dynamic "tag"` with `propagate_at_launch = true`.
*Source*: constitution §3.3; research-provider-resources.md §4–5.
*Rejected*: Module-set `ManagedBy`/`Environment` tags, which come from the caller's provider `default_tags` (constitution §3.3).

**File layout** (constitution §2.1, one file per AWS service):
- `versions.tf`, `variables.tf`, `locals.tf`
- `main.tf` (`data.aws_ami.selected` only)
- `check.tf`
- `elb.tf` (ALB, target group, listeners)
- `vpc.tf` (security groups and rules)
- `iam.tf`
- `ec2.tf` (launch template)
- `autoscaling.tf`
- `rds.tf`
- `outputs.tf`

`locals.tf` holds `https_enabled`, `database_enabled`, `check_subnet_ids`, `target_group_name_prefix` and `database_final_snapshot_identifier`, each with a one-line comment explaining why it exists. There is no `files/` or `templates/` directory, because user data is passed through.

### Resource Inventory

| Resource Type | Logical Name | Conditional | Depends On | Key Configuration | Schema Notes |
|---|---|---|---|---|---|
| `data.aws_ami` | `selected` | always | -- | `main.tf`. `most_recent = true`, `owners = var.ami.owners`, `filter { name = "name", values = [var.ami.name_pattern] }`. Supplies `id`, `architecture`, `root_device_name` | `filter` is set (input only) |
| `data.aws_subnets` | `in_vpc` | always (scoped inside `check "subnets_in_vpc"`) | -- | `check.tf`. `filter { name = "vpc-id", values = [var.vpc.vpc_id] }`. No count/for_each (scoped data) | `ids` is list(string) |
| `data.aws_ec2_instance_type` | `app` | always (scoped inside `check "ami_architecture"`) | -- | `check.tf`. `instance_type = var.app.instance_type` | `supported_architectures` is list(string) |
| `aws_security_group` | `web` | always | -- | `vpc.tf`. `name_prefix = "${var.web.name}-"`, fixed `description`, `vpc_id`, no inline rules, CBD | -- |
| `aws_security_group` | `app` | always | -- | `vpc.tf`. `name_prefix = "${var.app.name}-"`, `vpc_id`, no inline rules, CBD | -- |
| `aws_security_group` | `database` | `database` | -- | `vpc.tf`. `count = local.database_enabled ? 1 : 0`, `name_prefix = "${var.database.name}-"`, `vpc_id`, CBD, no egress rules exist | -- |
| `aws_vpc_security_group_ingress_rule` | `web_http` | always | `aws_security_group.web` | `vpc.tf`. tcp 80/80, `cidr_ipv4 = "0.0.0.0/0"`, `description`. Required in both modes (redirect or forward) | -- |
| `aws_vpc_security_group_ingress_rule` | `web_https` | `web.certificate_arn` | `aws_security_group.web` | `vpc.tf`. `count = local.https_enabled ? 1 : 0`, tcp 443/443, `cidr_ipv4 = "0.0.0.0/0"` | -- |
| `aws_vpc_security_group_egress_rule` | `web_to_app` | always | `aws_security_group.web`, `aws_security_group.app` | `vpc.tf`. tcp `app.port`, `referenced_security_group_id = aws_security_group.app.id` | -- |
| `aws_vpc_security_group_ingress_rule` | `app_from_web` | always | `aws_security_group.app`, `aws_security_group.web` | `vpc.tf`. tcp `app.port`, `referenced_security_group_id = aws_security_group.web.id`. No CIDR | -- |
| `aws_vpc_security_group_egress_rule` | `app_https` | always | `aws_security_group.app` | `vpc.tf`. tcp 443/443, `cidr_ipv4 = "0.0.0.0/0"`, preceded by `#trivy:ignore:AWS-0104` with justification | -- |
| `aws_vpc_security_group_egress_rule` | `app_to_database` | `database` | `aws_security_group.app`, `aws_security_group.database` | `vpc.tf`. `count = local.database_enabled ? 1 : 0`, tcp `database.port`, `referenced_security_group_id = aws_security_group.database[0].id` | -- |
| `aws_vpc_security_group_ingress_rule` | `database_from_app` | `database` | `aws_security_group.database`, `aws_security_group.app` | `vpc.tf`. `count = local.database_enabled ? 1 : 0`, tcp `database.port`, `referenced_security_group_id = aws_security_group.app.id` | -- |
| `aws_lb` | `web` | always | `aws_security_group.web` | `elb.tf`. `name = var.web.name`, `internal = false`, `load_balancer_type = "application"`, `subnets = values(var.vpc.public_subnet_ids)`, `security_groups = [web]`. `desync_mitigation_mode` left at the provider default `defensive` (ELB.12). `drop_invalid_header_fields`/`enable_deletion_protection`/`access_logs` not set (§7). Preceded by `#trivy:ignore:AWS-0053` and `#trivy:ignore:AWS-0052` | `subnets`, `security_groups` are set(string). `access_logs` list, unused |
| `aws_lb_target_group` | `app` | always | -- | `elb.tf`. `name_prefix = local.target_group_name_prefix`, `port = var.app.port`, `protocol = "HTTP"`, `target_type = "instance"`, `vpc_id`, `health_check { path = var.app.health_check_path, protocol = "HTTP", matcher = "200" }`, CBD | `health_check` is list (use `[0]`) |
| `aws_lb_listener` | `http` | always | `aws_lb.web`, `aws_lb_target_group.app` | `elb.tf`. Port 80 `HTTP`. `default_action.type = local.https_enabled ? "redirect" : "forward"`. `target_group_arn` only when forwarding. `dynamic "redirect"` gives `port = "443"` (**string**), `protocol = "HTTPS"`, `status_code = "HTTP_301"`. Preceded by `#trivy:ignore:AWS-0054` | `default_action` is list, `default_action.redirect` is list (use `[0]`, `length()` for absence) |
| `aws_lb_listener` | `https` | `web.certificate_arn` | `aws_lb.web`, `aws_lb_target_group.app` | `elb.tf`. `count = local.https_enabled ? 1 : 0`, port 443 `HTTPS`, `ssl_policy = var.web.ssl_policy`, `certificate_arn = var.web.certificate_arn`, `default_action { type = "forward", target_group_arn = app }` | `default_action` is list |
| `aws_iam_role` | `app` | always | -- | `iam.tf`. `name = var.app.name`, `assume_role_policy = jsonencode({...ec2.amazonaws.com, sts:AssumeRole...})`. No `inline_policy`/`managed_policy_arns` | `inline_policy` is set, unused |
| `aws_iam_instance_profile` | `app` | always | `aws_iam_role.app` | `iam.tf`. `name = var.app.name`, `role = aws_iam_role.app.name` | -- |
| `aws_iam_role_policy_attachment` | `app` | `for_each = var.app.managed_policy_arns` | `aws_iam_role.app` | `iam.tf`. `role = aws_iam_role.app.name`, `policy_arn = each.value`. Keys are static names | -- (addressed by key, for example `["ssm"]`) |
| `aws_launch_template` | `app` | always | `data.aws_ami.selected`, `aws_iam_instance_profile.app`, `aws_security_group.app` | `ec2.tf`. `name_prefix = "${var.app.name}-"` (`"${var.app.name}-lt-"` for a 1-char name, see Replacement-safe naming), `image_id = data.aws_ami.selected.id`, `instance_type`, `update_default_version = true`, `user_data = var.app.user_data == null ? null : base64encode(var.app.user_data)`, `iam_instance_profile { arn }`, `metadata_options` (IMDSv2, hop 1), `network_interfaces { associate_public_ip_address = false, delete_on_termination = true, security_groups = [app] }`, `block_device_mappings { device_name = data.aws_ami.selected.root_device_name, ebs { volume_size, volume_type = "gp3", encrypted = true, kms_key_id = var.app.ebs_kms_key_arn, delete_on_termination = true } }`, `tag_specifications { resource_type = "volume" }`, CBD | All nested blocks are list. **`ebs.encrypted`, `ebs.delete_on_termination` and `network_interfaces.associate_public_ip_address` are string-typed in 5.x** (compare with `"true"`/`"false"`). `network_interfaces.security_groups` is set(string) |
| `aws_autoscaling_group` | `app` | always | `aws_launch_template.app`, `aws_lb_target_group.app` | `autoscaling.tf`. `name = var.app.name`, `min_size`, `max_size`, no `desired_capacity`, `vpc_zone_identifier = values(var.vpc.private_subnet_ids)`, `target_group_arns = [app TG]`, `health_check_type = "ELB"`, `health_check_grace_period`, `launch_template { id, version = aws_launch_template.app.latest_version }`, `instance_refresh { strategy = "Rolling", preferences { min_healthy_percentage = 90 } }`, `dynamic "tag"` over merged tags with `propagate_at_launch = true` | **`tag` is set** (use a `for` filter plus `one()`, never `[0]`). `vpc_zone_identifier`, `target_group_arns` are set(string). `launch_template`, `instance_refresh`, `instance_refresh.preferences` are list. `launch_template.version` is string |
| `aws_db_subnet_group` | `database` | `database` | -- | `rds.tf`. `count = local.database_enabled ? 1 : 0`, `name = var.database.name`, `subnet_ids = values(var.vpc.database_subnet_ids)` | `subnet_ids` is set(string) |
| `aws_db_instance` | `database` | `database` | `aws_db_subnet_group.database`, `aws_security_group.database` | `rds.tf`. `count = local.database_enabled ? 1 : 0`, `identifier = var.database.name`, `engine = "postgres"`, `engine_version`, `instance_class`, `allocated_storage`, `storage_type = "gp3"`, `storage_encrypted = true`, `kms_key_id = var.database.kms_key_arn`, `db_name`, `username`, `manage_master_user_password = true`, `master_user_secret_kms_key_id = var.database.master_user_secret_kms_key_arn`, `port`, `multi_az`, `db_subnet_group_name = aws_db_subnet_group.database[0].name`, `vpc_security_group_ids = [database[0]]`, `publicly_accessible = false`, `backup_retention_period`, `deletion_protection`, `skip_final_snapshot`, `final_snapshot_identifier = local.database_final_snapshot_identifier`, `copy_tags_to_snapshot = true`, `auto_minor_version_upgrade = true`, `iam_database_authentication_enabled = true`. Never set `password`/`password_wo` | `vpc_security_group_ids` is set(string). **`master_user_secret` is a computed list attribute** (use `[0]` inside `try()`). In 5.x, `id` is the DBI resource ID, so use `identifier` for the name |

That is 21 managed resource blocks plus 3 data sources.

---

## 3. Interface Contract

### Inputs

Variables are declared in `variables.tf`. `vpc` is under `# Required` and the rest are under `# Optional`. Each object field with a default uses `optional(type, default)`. Every row in the Validation column is its own `validation` block (constitution §2.3). The `error_message` names the path and states the rule. Every rule on `database` is prefixed `var.database == null || ...`, which is null-safe [verified]. `try(can(...), true)` is never used.

| Variable | Type | Required | Default | Validation | Sensitive | Description |
|---|---|---|---|---|---|---|
| `vpc` | `object({...})` | Yes | -- | see fields | No | The existing network to deploy into. Pass the `craigsloggett-lab/vpc/aws` outputs directly. The module never creates networking. |
| `vpc.vpc_id` | `string` | Yes | -- | V1: `can(regex("^vpc-[0-9a-f]+$", var.vpc.vpc_id))` | No | ID of the existing VPC. |
| `vpc.public_subnet_ids` | `map(string)` | Yes | -- | V2: `length(var.vpc.public_subnet_ids) >= 2`. V3: `alltrue([for id in values(var.vpc.public_subnet_ids) : startswith(id, "subnet-")])` | No | Public subnets for the load balancer, keyed by subnet name. They must be in at least two AZs. |
| `vpc.private_subnet_ids` | `map(string)` | Yes | -- | V4: `length(var.vpc.private_subnet_ids) >= 2`. V5: `alltrue([... startswith(id, "subnet-")])` | No | Private subnets for the app fleet, keyed by subnet name. They should be in at least two AZs. |
| `vpc.database_subnet_ids` | `map(string)` | No | `{}` | V6: `alltrue([... startswith(id, "subnet-")])` | No | Database subnets, keyed by subnet name. Required (2 or more) only when `database` is set. |
| `web` | `object({...})` | No | `{}` | see fields | No | Web tier (internet-facing load balancer) settings. |
| `web.name` | `string` | No | `"three-tier-app-web"` | W1: `length(var.web.name) <= 32`. W2: `can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.web.name))`. W3: `!startswith(var.web.name, "internal-")` | No | Load balancer name and `Name` tag for web-tier resources. It must be unique per account and region. |
| `web.certificate_arn` | `string` | No | `null` | W4: `var.web.certificate_arn == null \|\| can(regex("^arn:aws[a-zA-Z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-zA-Z0-9-]+$", var.web.certificate_arn))` | No | ACM certificate ARN. When set, the module serves HTTPS on 443 and redirects HTTP to it. When null, it serves HTTP only on 80. |
| `web.ssl_policy` | `string` | No | `"ELBSecurityPolicy-TLS13-1-2-2021-06"` | W5: `contains(["ELBSecurityPolicy-TLS13-1-2-2021-06", "ELBSecurityPolicy-TLS13-1-2-Res-2021-06", "ELBSecurityPolicy-TLS13-1-3-2021-06", "ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04", "ELBSecurityPolicy-TLS13-1-2-Res-FIPS-2023-04", "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04"], var.web.ssl_policy)` | No | TLS policy for the HTTPS listener. Only TLS 1.2+ policies are allowed. |
| `app` | `object({...})` | No | `{}` | see fields | No | App tier (server fleet) settings. |
| `app.name` | `string` | No | `"three-tier-app"` | A1: `length(var.app.name) <= 64`. A2: `can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.app.name))` | No | Name for the ASG, IAM role and instance profile. It prefixes the launch template, security group and target group, and is the `Name` tag for app-tier resources. |
| `app.instance_type` | `string` | No | `"t3.micro"` | A3: `can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.app.instance_type))` | No | EC2 instance type. Its architecture must match the selected AMI (checked in `check.tf`). |
| `app.port` | `number` | No | `8080` | A4: `var.app.port >= 1 && var.app.port <= 65535` | No | Port the application listens on. It is the only port the load balancer can reach. |
| `app.health_check_path` | `string` | No | `"/"` | A5: `startswith(var.app.health_check_path, "/")`. A6: `length(var.app.health_check_path) <= 1024` | No | HTTP path the load balancer probes. Servers that fail it are replaced. |
| `app.health_check_grace_period` | `number` | No | `300` | A7: `var.app.health_check_grace_period >= 0` | No | Seconds after launch before failed health checks count. Size it to cover boot plus user data. |
| `app.min_size` | `number` | No | `2` | A8: `var.app.min_size >= 0` | No | Minimum fleet size. |
| `app.max_size` | `number` | No | `4` | A9: `var.app.max_size >= 1`. A10: `var.app.max_size >= var.app.min_size` | No | Maximum fleet size. |
| `app.root_volume_size` | `number` | No | `20` | A11: `var.app.root_volume_size >= 8 && var.app.root_volume_size <= 16384` | No | Root EBS volume size in GiB (gp3, always encrypted). |
| `app.user_data` | `string` | No | `null` | A12: `var.app.user_data == null \|\| length(var.app.user_data) <= 16384` | No | Plain-text boot script. The module base64-encodes it. Do not embed secrets, because anyone with instance metadata or DescribeInstanceAttribute access can read user data. |
| `app.ebs_kms_key_arn` | `string` | No | `null` | A13: `var.app.ebs_kms_key_arn == null \|\| can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.app.ebs_kms_key_arn))` | No | Customer-managed KMS key ARN for the root volume. When null, the AWS-managed `aws/ebs` key is used. The key policy MUST let the `AWSServiceRoleForAutoScaling` service-linked role use the key (`kms:CreateGrant`, `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`). Otherwise instances terminate at launch with `Client.InvalidKMSKey.InvalidState`. |
| `app.managed_policy_arns` | `map(string)` | No | `{ ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }` | A14: `alltrue([for arn in values(var.app.managed_policy_arns) : can(regex("^arn:aws[a-zA-Z-]*:iam::([0-9]{12}\|aws):policy/.+$", arn))])` | No | Managed IAM policies attached to the instance role, keyed by a static name you choose. The default grants Session Manager only, with no SSH. Setting this map replaces the default, so keep `ssm` if you need it. To read the database secret, add a policy granting `secretsmanager:GetSecretValue` on `db_instance_master_user_secret_arn`, plus `kms:Decrypt` if you use a secret CMK. Callers outside the `aws` partition must override the default ARN. |
| `ami` | `object({...})` | No | `{}` | see fields | No | App server image selection. The most recent match wins. |
| `ami.owners` | `list(string)` | No | `["amazon"]` | M1: `length(var.ami.owners) > 0` | No | AMI owner account IDs or aliases (`amazon`, `self`). It is always set, so image lookups are never unscoped. |
| `ami.name_pattern` | `string` | No | `"al2023-ami-2023.*-x86_64"` | M2: `length(var.ami.name_pattern) > 0` | No | AMI name filter (wildcards allowed). A newer matching image rolls the fleet on the next apply. |
| `database` | `object({...})` | No | `null` | D1 (cross-variable): `var.database == null \|\| length(var.vpc.database_subnet_ids) >= 2` | No | Data tier settings. When null, no data tier is created. When set (even `{}`), a single encrypted PostgreSQL instance is created in the database subnets. |
| `database.name` | `string` | No | `"three-tier-app-db"` | D2: `length(name) <= 63`. D3: `can(regex("^[a-z](-?[a-z0-9])*$", name))`, which means a leading letter, lowercase, no `--`, and no trailing hyphen | No | DB identifier, subnet group name, security group prefix and `Name` tag. The final snapshot is `<name>-final`. |
| `database.engine_version` | `string` | No | `"16"` | D4: `can(regex("^[0-9]+$", engine_version))`. D5: `try(tonumber(engine_version) >= 15, false)` | No | PostgreSQL **major** version, 15 or later. Minor versions upgrade automatically, and 15+ enforces TLS by default. |
| `database.instance_class` | `string` | No | `"db.t4g.micro"` | D6: `startswith(instance_class, "db.")` | No | RDS instance class. |
| `database.allocated_storage` | `number` | No | `20` | D7: `allocated_storage >= 20 && allocated_storage <= 65536` | No | Storage in GiB (gp3, always encrypted). |
| `database.db_name` | `string` | No | `"app"` | D8: `can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", db_name))` | No | Name of the initial database. |
| `database.username` | `string` | No | `"app_admin"` | D9: `can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", username))`. D10: `!contains(["postgres", "admin", "root", "rdsadmin"], lower(username))` | No | Master username. RDS generates the password and stores it in Secrets Manager. |
| `database.port` | `number` | No | `5432` | D11: `port >= 1150 && port <= 65535` | No | Database port. Only the app tier can reach it. |
| `database.multi_az` | `bool` | No | `true` | -- | No | Keep a synchronous standby in a second AZ. |
| `database.backup_retention_period` | `number` | No | `7` | D12: `backup_retention_period >= 1 && backup_retention_period <= 35` | No | Days of automated backups. Backups cannot be disabled. |
| `database.deletion_protection` | `bool` | No | `true` | -- | No | Block deletion of the database. To destroy, set it to false and apply first. |
| `database.skip_final_snapshot` | `bool` | No | `false` | -- | No | Skip the `<name>-final` snapshot on destroy. Set it to true only for disposable environments. |
| `database.kms_key_arn` | `string` | No | `null` | D13: `kms_key_arn == null \|\| can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", kms_key_arn))` | No | Customer-managed KMS key ARN for storage encryption. When null, `aws/rds` is used. Changing it replaces the database. |
| `database.master_user_secret_kms_key_arn` | `string` | No | `null` | D14: same KMS key ARN rule as D13, on this field | No | Customer-managed KMS key ARN for the master-password secret. When null, `aws/secretsmanager` is used. |
| `tags` | `map(string)` | No | `{}` | -- | No | Tags applied to every resource beneath the module's `Name` tag. A `Name` key here is ignored. |

That is 6 variables with 34 object fields and 41 validation blocks. No input is sensitive: the only secret (the DB password) never passes through Terraform.

### Outputs

Every output from a `count`-toggled resource uses `try(<resource>[0].<attr>, null)`, per constitution §2.4. The secret ARN is `try(aws_db_instance.database[0].master_user_secret[0].secret_arn, null)`. No output is sensitive, because an ARN is not a secret.

| Output | Type | Conditional On | Description |
|---|---|---|---|
| `alb_arn` | `string` | always | ARN of the load balancer. |
| `alb_arn_suffix` | `string` | always | ARN suffix of the load balancer, for CloudWatch metric dimensions. |
| `alb_dns_name` | `string` | always | DNS name of the load balancer. Point a CNAME or alias record at it. |
| `alb_zone_id` | `string` | always | Hosted zone ID of the load balancer, for Route 53 alias records. |
| `http_listener_arn` | `string` | always | ARN of the port-80 listener (redirects when HTTPS is enabled, forwards otherwise). |
| `https_listener_arn` | `string` | `web.certificate_arn` | ARN of the port-443 listener. Attach extra certificates or rules to it. Null without a certificate. |
| `target_group_arn` | `string` | always | ARN of the app target group. |
| `target_group_arn_suffix` | `string` | always | ARN suffix of the target group, for CloudWatch metric dimensions. |
| `web_security_group_id` | `string` | always | ID of the load balancer security group. |
| `app_security_group_id` | `string` | always | ID of the app server security group. Reference it to allow app access to other services. |
| `autoscaling_group_name` | `string` | always | Name of the ASG. Attach scaling policies to it. |
| `autoscaling_group_arn` | `string` | always | ARN of the ASG. |
| `launch_template_id` | `string` | always | ID of the launch template. |
| `launch_template_latest_version` | `number` | always | Latest launch template version, which is the version the ASG runs. |
| `iam_role_name` | `string` | always | Name of the instance role. Attach extra policies to it. |
| `iam_role_arn` | `string` | always | ARN of the instance role. |
| `iam_instance_profile_arn` | `string` | always | ARN of the instance profile. |
| `ami_id` | `string` | always | ID of the AMI the launch template currently uses. |
| `db_instance_identifier` | `string` | `database` | RDS instance identifier. Null without a data tier. |
| `db_instance_arn` | `string` | `database` | RDS instance ARN. Null without a data tier. |
| `db_instance_address` | `string` | `database` | Database hostname. Null without a data tier. |
| `db_instance_endpoint` | `string` | `database` | Database `host:port`. Null without a data tier. |
| `db_instance_port` | `number` | `database` | Database port. Null without a data tier. |
| `db_instance_master_user_secret_arn` | `string` | `database` | ARN of the Secrets Manager secret holding the master credentials. Grant `secretsmanager:GetSecretValue` on it (and `kms:Decrypt` on its key) to readers. Null without a data tier. |
| `db_subnet_group_name` | `string` | `database` | Name of the DB subnet group. Null without a data tier. |
| `database_security_group_id` | `string` | `database` | ID of the database security group. Null without a data tier. |

That is 26 outputs.

---

## 4. Security Controls

| Control | Enforcement | Configurable? | Reference |
|---|---|---|---|
| Encryption at rest: app volumes | Launch template root volume `encrypted = true`, gp3. `kms_key_id` from `app.ebs_kms_key_arn`, or `aws/ebs` when null | Key: Yes (`app.ebs_kms_key_arn`). Encryption: **No**, because unencrypted app disks have no legitimate use in this module and constitution §3.2 requires encryption on by default | FSBP EC2.3. CIS AWS 2.2.1. WA SEC08-BP02 |
| Encryption at rest: database storage and snapshots | `storage_encrypted = true`. `kms_key_id` from `database.kms_key_arn`, or `aws/rds`. Snapshots inherit the encryption | Key: Yes. Encryption: **No**, for the same reason (RDS encryption cannot be added in place later) | FSBP RDS.3, RDS.4. CIS AWS 2.3.1. WA SEC08-BP02 |
| Encryption at rest: database credentials | `manage_master_user_password = true`, so the password lives only in Secrets Manager, is rotated every 7 days by RDS, and never enters config or state. Secret key from `database.master_user_secret_kms_key_arn`, or `aws/secretsmanager` | Key: Yes. Managed password: **No**, because the alternatives put the password in state | FSBP SecretsManager.1/.4. WA SEC02-BP03, SEC08-BP02 |
| Encryption in transit: client to web tier | With `web.certificate_arn`: HTTPS:443 with `ssl_policy` from a TLS 1.2+ allowlist (default `ELBSecurityPolicy-TLS13-1-2-2021-06`), and HTTP:80 returns `HTTP_301` to HTTPS. Without a certificate: plain HTTP (user-directed, see §7 deviation 3) | Yes. Presence of `web.certificate_arn`. `web.ssl_policy` is limited to secure values | FSBP ELB.1, ELB.17. WA SEC09-BP02 |
| Encryption in transit: web to app | HTTP between ALB and instances inside the VPC (TLS terminates at the ALB) | No. This is the standard TLS-offload pattern and needs no instance certificates. It is accepted in the residual table below | WA SEC09-BP02 (accepted) |
| Encryption in transit: app to database | The `engine_version >= 15` validation means the default parameter group sets `rds.force_ssl = 1`, so non-TLS connections are refused | **No**. Hardcoded through validation, because a lower engine would silently drop TLS enforcement | WA SEC09-BP02. RDS PostgreSQL SSL docs |
| Public access: web tier | Internet-facing by design. Only 80 and 443 are open to `0.0.0.0/0` | No. This is the purpose of the tier (FR-02). Trivy AWS-0053 is suppressed with a justification | FSBP EC2.18. WA SEC05-BP02 |
| Public access: app tier | Private subnets only. ENI `associate_public_ip_address = false`. Ingress only from the web SG on `app.port`. No SSH (Session Manager instead) | **No**. Hardcoded, because public app servers defeat the tier model | FSBP EC2.9, EC2.25, EC2.13, EC2.53. CIS AWS 5.2. WA SEC05-BP02 |
| Public access: data tier | `publicly_accessible = false`, database subnets only, ingress only from the app SG on `database.port`, no egress | **No**. Hardcoded, because constitution §3.2 says RDS MUST NOT be public | FSBP RDS.2. CIS AWS 2.3.3. WA SEC05-BP02 |
| Network least privilege | Seven fixed SG rules. SG-to-SG references between tiers. `0.0.0.0/0` only on web ingress 80/443 and app egress 443 (user-directed. Trivy AWS-0104 is suppressed with a justification) | No. The architecture fixes the rules. The port values follow `app.port` and `database.port` | CIS AWS 5.2/5.3. WA SEC05-BP01 |
| Instance metadata | `http_tokens = "required"`, `http_endpoint = "enabled"`, `http_put_response_hop_limit = 1` | **No**. Hardcoded, because constitution §3.2 mandates it on every launch template | FSBP EC2.8, EC2.170. WA SEC06-BP02 |
| IAM least privilege | The role trusts only `ec2.amazonaws.com`. No inline policies. Only caller-listed managed policies are attached, and the default is `AmazonSSMManagedInstanceCore` only. RDS IAM authentication is on | Yes. `app.managed_policy_arns` is caller-controlled, and the secure default is minimal | CIS AWS 1.16. FSBP RDS.10. WA SEC03-BP02 |
| Credentials | No credential inputs. No `provider` blocks. Instance credentials come only through the instance profile. The admin username rejects default names | Username: Yes (validated) | FSBP RDS.25. Constitution §3.1. WA SEC02-BP02 |
| Logging | ALB access logs: **not enabled**. RDS CloudWatch log exports and Performance Insights: **not enabled**. The user declined both in clarification (Q1). RDS automated backups and snapshots provide the data audit trail | Not in this release. See §7 OQ-2 and OQ-3 | FSBP ELB.5, RDS.9, RDS.36 (**unmet**, see residual table). WA SEC04-BP01 |
| Resilience | ALB 2+ subnets (V2), ASG 2+ subnets (V4), `multi_az = true`, `backup_retention_period = 7` (minimum 1), `deletion_protection = true`, final snapshot on destroy, rolling instance refresh at 90% healthy | Yes. All are secure by default and can be relaxed per `database` field | FSBP ELB.13, AutoScaling.1/.2, RDS.5, RDS.8, RDS.11. WA REL10-BP01, REL09-BP02 |
| Tagging | `merge(var.tags, { Name = var.<object>.name })` on every taggable resource. ASG tags propagate to instances. Launch template tags volumes. `copy_tags_to_snapshot = true` | Yes (`tags`). `Name` is always module-set | FSBP RDS.17, AutoScaling.10. Constitution §3.3. WA COST03-BP02 |

**Control-to-test mapping** (every row above has at least one value assertion in §5):

| Control | Unit runs asserting the enforced value |
|---|---|
| Encryption at rest: app volumes | `unit_basic` `app_tier_defaults`. `unit_complete` `full_features_app` |
| Encryption at rest: database | `unit_complete` `full_features_database`. `unit_edge_cases` `database_protections_relaxed` |
| Database credentials | `unit_complete` `full_features_database` |
| Client-to-web TLS | `unit_complete` `full_features_web`. `unit_edge_cases` `https_without_database` |
| App-to-database TLS | `unit_validation` `reject_database_engine_version_below_15` |
| Public access (all tiers) | `unit_basic` `web_tier_defaults`, `app_tier_defaults`, `network_defaults`. `unit_complete` `full_features_database` |
| Network least privilege | `unit_basic` `network_defaults`. `unit_complete` `full_features_network` |
| Instance metadata | `unit_basic` `app_tier_defaults` |
| IAM least privilege | `unit_basic` `iam_defaults`. `unit_edge_cases` `no_managed_policies` |
| Credentials | `unit_complete` `full_features_database`. `unit_validation` `reject_database_username_reserved` |
| Logging (documents the user-directed absence) | `unit_basic` `web_tier_defaults` (`length(aws_lb.web.access_logs) == 0`) |
| Resilience | `unit_basic` `app_tier_defaults`. `unit_complete` `full_features_database` |
| Tagging | `unit_basic` `tags_and_outputs`. `unit_edge_cases` `consumer_name_tag_is_overridden` |

**Accepted residual findings** (NFR-05). They are recorded here, and the open ones are carried into §7:

| Finding | Why unmet | Risk |
|---|---|---|
| ELB.4 / Trivy AWS-0052: drop invalid headers | Not selected by the user | Medium (P2). §7 OQ-1 |
| ELB.5: ALB access logs | Not selected by the user | Medium (P2). §7 OQ-2 |
| ELB.6: ALB deletion protection | Not selected by the user | Low (P3). §7 OQ-1 |
| RDS.9, RDS.36: PostgreSQL log exports. RDS.6: enhanced monitoring | Not selected by the user | Medium (P2). §7 OQ-3 |
| ELB.18 (possible) / Trivy AWS-0054: HTTP listener | Redirect-only with a certificate. Forwards without one (user-directed) | High (P1) **only** when deployed without a certificate in production. §7 deviation 3 |
| ELB.21 / ELB.22: HTTP from ALB to targets | TLS offload at the ALB | Low (P3) |
| ELB.16: WAF | Out of scope | Medium (P2) for public production apps |
| RDS.23: default port 5432 | Default kept for compatibility. Callers can set `database.port` | Low (P3) |
| RDS.19–RDS.22: event subscriptions. EC2.28: EBS backup plan. AutoScaling.6: multiple instance types | Out of scope. The app tier is stateless. A single `instance_type` keeps the interface simple | Low (P3) |
| Trivy AWS-0104: app egress `0.0.0.0/0:443` | User-directed (clarification Q2). VPC endpoints are the caller's option | Medium (P2) |

---

## 5. Test Scenarios

### Test Strategy

- **Module source**: Tests run against the **root module directly**. `run` blocks have no `module {}` blocks. Assertions use `resource_type.name.attribute`.
- **Files** (constitution §5.3). `tests/validate.tftest.hcl` is deleted.
  - Unit tests with `mock_provider "aws"` and `command = plan` in **every** run: `unit_basic.tftest.hcl`, `unit_complete.tftest.hcl`, `unit_edge_cases.tftest.hcl` and `unit_validation.tftest.hcl`.
  - Acceptance tests with the real provider and `command = plan`: `acceptance.tftest.hcl`.
  - Integration tests with the real provider and `command = apply`: `integration.tftest.hcl`.
  - A `run` without `command` defaults to apply, so every unit run MUST say `command = plan`.
- **Mock data**: Each unit file contains the same fixture header (below). `mock_data` is required for all three data sources.
  - `aws_ami` needs a realistic `root_device_name` and a matching `architecture`.
  - `aws_ec2_instance_type` needs `supported_architectures`, so `check.ami_architecture` passes.
  - `aws_subnets` needs `ids` covering every fixture subnet, so `check.subnets_in_vpc` passes. An unmocked check failure would fail every run.
  - The trust policy is built with `jsonencode()`, so no `aws_iam_policy_document` mock is needed.
- **Wiring overrides**: File-level `override_resource { override_during = plan }` blocks give the three security groups, the target group and the instance profile known IDs and ARNs at plan. Tests can then assert real wiring (for example `referenced_security_group_id == aws_security_group.database[0].id`) instead of mere existence. This was verified on Terraform 1.15.2 with aws 5.100.0.
- **Plan-time limits**: Without an override, provider-computed values are unknown at plan, and asserting them fails with "Unknown condition value" [verified]. Examples are `arn`, `dns_name`, `endpoint`, `latest_version`, `master_user_secret` and the random `name` behind a `name_prefix`. Such assertions are marked `[plan-unknown]` and moved to the acceptance or integration files. Outputs of count-0 resources are known `null` and are asserted directly.
- **Set-typed paths**:
  - `aws_autoscaling_group.app.tag` is a set. Use `one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Name"])`, never `[0]`.
  - `subnets`, `security_groups`, `vpc_zone_identifier`, `target_group_arns`, `subnet_ids` and `vpc_security_group_ids` are `set(string)`. Use `contains()`, `length()` or `== toset([...])`.
  - `ebs.encrypted` and `network_interfaces.associate_public_ip_address` are strings, so compare them with `"true"`/`"false"`.
- **Failure isolation**: An unexpected error in a run skips every later run in the same file [verified]. That is why validation lives only in `unit_validation.tftest.hcl` and module-level validation catches provider limits. Accept runs come before reject runs in that file.
- **Long-string boundaries**: `range()` is capped at 1024 elements, so build long strings with nested `join`, for example `join("", [for i in range(16) : join("", [for j in range(1024) : "a"])])`, which is 16384 characters [verified].

**Shared unit-test fixture** (copied verbatim at the top of each `unit_*.tftest.hcl`):

```hcl
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
```

In this section, `TG_ARN` means the target group ARN from the fixture, and `SG_WEB`, `SG_APP` and `SG_DB` mean the three overridden security group IDs.

### Unit Tests

#### Scenario: Secure Defaults (basic)

**Purpose**: The module plans with only `vpc`, and every security control is on by default.
**File**: `tests/unit_basic.tftest.hcl`
**Command**: `plan` (mock providers)

**Inputs**: The fixture `vpc` only. No other variables are set.

**Assertions**:

`run "web_tier_defaults"`:
- ALB is internet-facing: `aws_lb.web.internal == false`
- ALB type: `aws_lb.web.load_balancer_type == "application"`
- ALB name: `aws_lb.web.name == "three-tier-app-web"`
- ALB in public subnets only: `aws_lb.web.subnets == toset(["subnet-0000000000000000a", "subnet-0000000000000000b"])`
- ALB uses the web SG: `contains(aws_lb.web.security_groups, "sg-0000000000000web0")`
- No access logs (user-directed): `length(aws_lb.web.access_logs) == 0`
- No HTTPS listener without a certificate: `length(aws_lb_listener.https) == 0`
- HTTP listener port: `aws_lb_listener.http.port == 80`
- HTTP listener protocol: `aws_lb_listener.http.protocol == "HTTP"`
- HTTP forwards when there is no certificate: `aws_lb_listener.http.default_action[0].type == "forward"`
- HTTP forwards to the app TG: `aws_lb_listener.http.default_action[0].target_group_arn == aws_lb_target_group.app.arn`
- No redirect block: `length(aws_lb_listener.http.default_action[0].redirect) == 0`
- TG port: `aws_lb_target_group.app.port == 8080`
- TG protocol: `aws_lb_target_group.app.protocol == "HTTP"`
- TG health path: `aws_lb_target_group.app.health_check[0].path == "/"`
- TG name prefix (6 characters): `aws_lb_target_group.app.name_prefix == "three-"`
- TG VPC: `aws_lb_target_group.app.vpc_id == "vpc-0123456789abcdef0"`

`run "app_tier_defaults"`:
- IMDSv2 required: `aws_launch_template.app.metadata_options[0].http_tokens == "required"`
- IMDS endpoint on: `aws_launch_template.app.metadata_options[0].http_endpoint == "enabled"`
- IMDS hop limit: `aws_launch_template.app.metadata_options[0].http_put_response_hop_limit == 1`
- Root volume encrypted: `aws_launch_template.app.block_device_mappings[0].ebs[0].encrypted == "true"`
- AWS-managed key by default: `aws_launch_template.app.block_device_mappings[0].ebs[0].kms_key_id == null`
- gp3: `aws_launch_template.app.block_device_mappings[0].ebs[0].volume_type == "gp3"`
- Size: `aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 20`
- Root device from AMI: `aws_launch_template.app.block_device_mappings[0].device_name == "/dev/xvda"`
- No public IP: `aws_launch_template.app.network_interfaces[0].associate_public_ip_address == "false"`
- App SG on the ENI: `contains(aws_launch_template.app.network_interfaces[0].security_groups, "sg-0000000000000app0")`
- Instance profile attached: `aws_launch_template.app.iam_instance_profile[0].arn == "arn:aws:iam::123456789012:instance-profile/three-tier-app"`
- AMI from the data source: `aws_launch_template.app.image_id == "ami-0123456789abcdef0"`
- Instance type: `aws_launch_template.app.instance_type == "t3.micro"`
- No user data by default: `aws_launch_template.app.user_data == null`
- ASG replaces on ELB health: `aws_autoscaling_group.app.health_check_type == "ELB"`
- Grace period: `aws_autoscaling_group.app.health_check_grace_period == 300`
- Min size: `aws_autoscaling_group.app.min_size == 2`
- Max size: `aws_autoscaling_group.app.max_size == 4`
- ASG in private subnets only: `aws_autoscaling_group.app.vpc_zone_identifier == toset(["subnet-0000000000000001a", "subnet-0000000000000001b"])`
- ASG registered in the TG: `contains(aws_autoscaling_group.app.target_group_arns, TG_ARN)`
- Rolling refresh: `aws_autoscaling_group.app.instance_refresh[0].strategy == "Rolling"`
- Refresh keeps 90% healthy: `aws_autoscaling_group.app.instance_refresh[0].preferences[0].min_healthy_percentage == 90`
- ASG follows the latest LT version: `aws_autoscaling_group.app.launch_template[0].version == tostring(aws_launch_template.app.latest_version)` `[plan-unknown]` (moved to integration)

`run "iam_defaults"`:
- EC2-only trust: `jsondecode(aws_iam_role.app.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"`
- AssumeRole only: `jsondecode(aws_iam_role.app.assume_role_policy).Statement[0].Action == "sts:AssumeRole"`
- Role name: `aws_iam_role.app.name == "three-tier-app"`
- Profile wraps the role: `aws_iam_instance_profile.app.role == "three-tier-app"`
- One policy by default: `length(aws_iam_role_policy_attachment.app) == 1`
- SSM only: `aws_iam_role_policy_attachment.app["ssm"].policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"`

`run "network_defaults"`:
- HTTP ingress from the internet on the web SG: `aws_vpc_security_group_ingress_rule.web_http.security_group_id == "sg-0000000000000web0"`
- HTTP ingress CIDR: `aws_vpc_security_group_ingress_rule.web_http.cidr_ipv4 == "0.0.0.0/0"`
- HTTP ingress port: `aws_vpc_security_group_ingress_rule.web_http.from_port == 80`
- No 443 ingress without a certificate: `length(aws_vpc_security_group_ingress_rule.web_https) == 0`
- Web egress only to the app SG: `aws_vpc_security_group_egress_rule.web_to_app.referenced_security_group_id == "sg-0000000000000app0"`
- Web egress port: `aws_vpc_security_group_egress_rule.web_to_app.from_port == 8080`
- App ingress only from the web SG: `aws_vpc_security_group_ingress_rule.app_from_web.referenced_security_group_id == "sg-0000000000000web0"`
- App ingress has no CIDR: `aws_vpc_security_group_ingress_rule.app_from_web.cidr_ipv4 == null`
- App ingress port: `aws_vpc_security_group_ingress_rule.app_from_web.to_port == 8080`
- App HTTPS egress CIDR: `aws_vpc_security_group_egress_rule.app_https.cidr_ipv4 == "0.0.0.0/0"`
- App HTTPS egress port: `aws_vpc_security_group_egress_rule.app_https.from_port == 443`
- App HTTPS egress protocol: `aws_vpc_security_group_egress_rule.app_https.ip_protocol == "tcp"`
- No database egress without a data tier: `length(aws_vpc_security_group_egress_rule.app_to_database) == 0`
- No database ingress without a data tier: `length(aws_vpc_security_group_ingress_rule.database_from_app) == 0`

`run "data_tier_absent"`:
- No DB instance: `length(aws_db_instance.database) == 0`
- No subnet group: `length(aws_db_subnet_group.database) == 0`
- No DB SG: `length(aws_security_group.database) == 0`
- Endpoint output null: `output.db_instance_endpoint == null`
- Secret output null: `output.db_instance_master_user_secret_arn == null`
- DB SG output null: `output.database_security_group_id == null`
- HTTPS listener output null: `output.https_listener_arn == null`

`run "tags_and_outputs"`:
- ALB Name tag: `aws_lb.web.tags["Name"] == "three-tier-app-web"`
- App SG Name tag: `aws_security_group.app.tags["Name"] == "three-tier-app"`
- Rule Name tag: `aws_vpc_security_group_egress_rule.app_https.tags["Name"] == "three-tier-app"`
- Volume tags: `aws_launch_template.app.tag_specifications[0].resource_type == "volume"`
- Volume Name tag: `aws_launch_template.app.tag_specifications[0].tags["Name"] == "three-tier-app"`
- Instances get Name: `one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Name"]) == "three-tier-app"`
- Name propagates: `one([for t in aws_autoscaling_group.app.tag : t.propagate_at_launch if t.key == "Name"]) == true`
- AMI output: `output.ami_id == "ami-0123456789abcdef0"`
- ASG name output: `output.autoscaling_group_name == "three-tier-app"`
- Role name output: `output.iam_role_name == "three-tier-app"`
- DNS output: `output.alb_dns_name` `[plan-unknown]` (moved to integration)

#### Scenario: Full Features (complete)

**Purpose**: With every optional input set, all conditional resources exist, all overrides take effect, and every security control still holds.
**File**: `tests/unit_complete.tftest.hcl`
**Command**: `plan` (mock providers)

**Inputs** (a file-level `variables` block that adds to the fixture):

```hcl
variables {
  web = {
    name            = "complete-web"
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
  }
  app = {
    name                      = "complete-app"
    instance_type             = "t3.small"
    port                      = 8443
    health_check_path         = "/healthz"
    health_check_grace_period = 600
    min_size                  = 3
    max_size                  = 6
    root_volume_size          = 50
    user_data                 = "#!/bin/bash\necho ready"
    ebs_kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-1111-2222-3333-444444444444"
    managed_policy_arns = {
      ssm     = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      secrets = "arn:aws:iam::123456789012:policy/complete-app-secrets"
    }
  }
  ami = {
    owners       = ["amazon"]
    name_pattern = "al2023-ami-2023.*-x86_64"
  }
  database = {
    name                           = "complete-db"
    engine_version                 = "17"
    instance_class                 = "db.t4g.small"
    allocated_storage              = 50
    db_name                        = "orders"
    username                       = "orders_admin"
    port                           = 5433
    multi_az                       = true
    backup_retention_period        = 14
    deletion_protection            = true
    skip_final_snapshot            = false
    kms_key_arn                    = "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-1111-2222-3333-444444444444"
    master_user_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/cccccccc-1111-2222-3333-444444444444"
  }
  tags = {
    Environment = "test"
    CostCenter  = "1234"
  }
}
```

**Assertions**:

`run "full_features_web"`:
- HTTPS listener exists: `length(aws_lb_listener.https) == 1`
- HTTPS listener port: `aws_lb_listener.https[0].port == 443`
- HTTPS listener protocol: `aws_lb_listener.https[0].protocol == "HTTPS"`
- Caller TLS policy: `aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"`
- Certificate wired: `aws_lb_listener.https[0].certificate_arn == "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"`
- HTTPS forwards to the TG: `aws_lb_listener.https[0].default_action[0].target_group_arn == aws_lb_target_group.app.arn`
- HTTP redirects: `aws_lb_listener.http.default_action[0].type == "redirect"`
- Redirect to HTTPS: `aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"`
- Redirect port (string): `aws_lb_listener.http.default_action[0].redirect[0].port == "443"`
- Permanent redirect: `aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"`
- 443 ingress exists: `aws_vpc_security_group_ingress_rule.web_https[0].from_port == 443`
- 443 ingress CIDR: `aws_vpc_security_group_ingress_rule.web_https[0].cidr_ipv4 == "0.0.0.0/0"`
- TG port follows the app: `aws_lb_target_group.app.port == 8443`
- TG health path: `aws_lb_target_group.app.health_check[0].path == "/healthz"`
- TG prefix from the app name: `aws_lb_target_group.app.name_prefix == "comple"`
- HTTPS listener ARN output: `output.https_listener_arn` `[plan-unknown]` (moved to integration)

`run "full_features_app"`:
- User data encoded: `aws_launch_template.app.user_data == base64encode("#!/bin/bash\necho ready")`
- User data decodes: `base64decode(aws_launch_template.app.user_data) == "#!/bin/bash\necho ready"`
- CMK on the root volume: `aws_launch_template.app.block_device_mappings[0].ebs[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-1111-2222-3333-444444444444"`
- Still encrypted: `aws_launch_template.app.block_device_mappings[0].ebs[0].encrypted == "true"`
- IMDSv2 still required: `aws_launch_template.app.metadata_options[0].http_tokens == "required"`
- Volume size: `aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 50`
- Instance type: `aws_launch_template.app.instance_type == "t3.small"`
- Min size: `aws_autoscaling_group.app.min_size == 3`
- Max size: `aws_autoscaling_group.app.max_size == 6`
- Grace period: `aws_autoscaling_group.app.health_check_grace_period == 600`
- Two policies: `length(aws_iam_role_policy_attachment.app) == 2`
- Extra policy wired: `aws_iam_role_policy_attachment.app["secrets"].policy_arn == "arn:aws:iam::123456789012:policy/complete-app-secrets"`
- Consumer tag propagated to instances: `one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Environment"]) == "test"`

`run "full_features_database"`:
- One instance: `length(aws_db_instance.database) == 1`
- Engine: `aws_db_instance.database[0].engine == "postgres"`
- Major version: `aws_db_instance.database[0].engine_version == "17"`
- Identifier: `aws_db_instance.database[0].identifier == "complete-db"`
- Storage encrypted: `aws_db_instance.database[0].storage_encrypted == true`
- Storage CMK: `aws_db_instance.database[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-1111-2222-3333-444444444444"`
- Not public: `aws_db_instance.database[0].publicly_accessible == false`
- Managed password: `aws_db_instance.database[0].manage_master_user_password == true`
- Secret CMK: `aws_db_instance.database[0].master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/cccccccc-1111-2222-3333-444444444444"`
- IAM authentication: `aws_db_instance.database[0].iam_database_authentication_enabled == true`
- Multi-AZ: `aws_db_instance.database[0].multi_az == true`
- Backups: `aws_db_instance.database[0].backup_retention_period == 14`
- Deletion protection: `aws_db_instance.database[0].deletion_protection == true`
- Final snapshot kept: `aws_db_instance.database[0].skip_final_snapshot == false`
- Snapshot name derived: `aws_db_instance.database[0].final_snapshot_identifier == "complete-db-final"`
- Tags to snapshots: `aws_db_instance.database[0].copy_tags_to_snapshot == true`
- Auto minor upgrades: `aws_db_instance.database[0].auto_minor_version_upgrade == true`
- gp3: `aws_db_instance.database[0].storage_type == "gp3"`
- Custom username: `aws_db_instance.database[0].username == "orders_admin"`
- Port: `aws_db_instance.database[0].port == 5433`
- DB SG attached: `contains(aws_db_instance.database[0].vpc_security_group_ids, "sg-00000000000000db0")`
- Subnet group has database subnets: `aws_db_subnet_group.database[0].subnet_ids == toset(["subnet-0000000000000002a", "subnet-0000000000000002b"])`
- Subnet group name: `aws_db_subnet_group.database[0].name == "complete-db"`

`run "full_features_network"`:
- App-to-database egress targets the DB SG: `aws_vpc_security_group_egress_rule.app_to_database[0].referenced_security_group_id == aws_security_group.database[0].id`
- On the app SG: `aws_vpc_security_group_egress_rule.app_to_database[0].security_group_id == "sg-0000000000000app0"`
- On the DB port: `aws_vpc_security_group_egress_rule.app_to_database[0].from_port == 5433`
- DB ingress only from the app SG: `aws_vpc_security_group_ingress_rule.database_from_app[0].referenced_security_group_id == "sg-0000000000000app0"`
- DB ingress on the DB SG: `aws_vpc_security_group_ingress_rule.database_from_app[0].security_group_id == "sg-00000000000000db0"`
- DB ingress port: `aws_vpc_security_group_ingress_rule.database_from_app[0].to_port == 5433`
- Web egress follows the app port: `aws_vpc_security_group_egress_rule.web_to_app.from_port == 8443`
- DB SG in the VPC: `aws_security_group.database[0].vpc_id == "vpc-0123456789abcdef0"`

`run "full_features_outputs"`:
- Identifier output: `output.db_instance_identifier == "complete-db"`
- Port output: `output.db_instance_port == 5433`
- Subnet group output: `output.db_subnet_group_name == "complete-db"`
- DB SG output: `output.database_security_group_id == "sg-00000000000000db0"`
- Name wins, consumer tags merged: `aws_db_instance.database[0].tags["Name"] == "complete-db"`
- Consumer tag present: `aws_db_instance.database[0].tags["CostCenter"] == "1234"`
- Secret ARN output: `output.db_instance_master_user_secret_arn` `[plan-unknown]` (moved to integration)
- Endpoint output: `output.db_instance_endpoint` `[plan-unknown]` (moved to integration)

#### Scenario: Feature Interactions (edge cases)

**Purpose**: Non-obvious toggle combinations and precedence behave correctly.
**File**: `tests/unit_edge_cases.tftest.hcl`
**Command**: `plan` (mock providers)

**Sub-scenario: HTTPS without a data tier.** `run "https_without_database"`
**Inputs**:

```hcl
web = { certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc" }
```

**Assertions**:
- HTTPS listener exists: `length(aws_lb_listener.https) == 1`
- Default TLS policy applied: `aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"`
- HTTP redirects: `aws_lb_listener.http.default_action[0].type == "redirect"`
- HTTP stops forwarding: `aws_lb_listener.http.default_action[0].target_group_arn == null`
- No DB instance: `length(aws_db_instance.database) == 0`
- No database egress on the app SG: `length(aws_vpc_security_group_egress_rule.app_to_database) == 0`

**Sub-scenario: Data tier without HTTPS.** `run "database_without_https"`
**Inputs**:

```hcl
database = {}
```

**Assertions**:
- All five data-tier resources exist: `length(aws_db_instance.database) == 1`
- Subnet group exists: `length(aws_db_subnet_group.database) == 1`
- DB SG exists: `length(aws_security_group.database) == 1`
- DB ingress rule exists: `length(aws_vpc_security_group_ingress_rule.database_from_app) == 1`
- App egress rule exists: `length(aws_vpc_security_group_egress_rule.app_to_database) == 1`
- Default port: `aws_vpc_security_group_egress_rule.app_to_database[0].from_port == 5432`
- HTTP still forwards: `aws_lb_listener.http.default_action[0].type == "forward"`
- No HTTPS listener: `length(aws_lb_listener.https) == 0`
- Default engine: `aws_db_instance.database[0].engine_version == "16"`
- Default username is not `postgres`: `aws_db_instance.database[0].username == "app_admin"`

**Sub-scenario: Resilience relaxed, security unchanged.** `run "database_protections_relaxed"`
**Inputs**:

```hcl
database = {
  multi_az                = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 1
}
```

**Assertions**:
- Single-AZ honoured: `aws_db_instance.database[0].multi_az == false`
- Deletion protection off: `aws_db_instance.database[0].deletion_protection == false`
- Skip snapshot honoured: `aws_db_instance.database[0].skip_final_snapshot == true`
- Minimum backups: `aws_db_instance.database[0].backup_retention_period == 1`
- Encryption cannot be relaxed: `aws_db_instance.database[0].storage_encrypted == true`
- Still private: `aws_db_instance.database[0].publicly_accessible == false`
- Still a managed password: `aws_db_instance.database[0].manage_master_user_password == true`

**Sub-scenario: Consumer `Name` tag cannot override module names.** `run "consumer_name_tag_is_overridden"`
**Inputs**:

```hcl
tags     = { Name = "consumer", Environment = "dev" }
database = {}
```

**Assertions**:
- ALB Name: `aws_lb.web.tags["Name"] == "three-tier-app-web"`
- App SG Name: `aws_security_group.app.tags["Name"] == "three-tier-app"`
- DB Name: `aws_db_instance.database[0].tags["Name"] == "three-tier-app-db"`
- Instance Name: `one([for t in aws_autoscaling_group.app.tag : t.value if t.key == "Name"]) == "three-tier-app"`
- Other tags kept: `aws_lb.web.tags["Environment"] == "dev"`

**Sub-scenario: No managed policies.** `run "no_managed_policies"`
**Inputs**:

```hcl
app = { managed_policy_arns = {} }
```

**Assertions**:
- No attachments: `length(aws_iam_role_policy_attachment.app) == 0`
- Role still created: `aws_iam_role.app.name == "three-tier-app"`
- Profile still attached to the LT: `aws_launch_template.app.iam_instance_profile[0].arn == "arn:aws:iam::123456789012:instance-profile/three-tier-app"`

**Sub-scenario: Data-backed checks fail loudly.** This sub-scenario has two runs.

`run "ami_architecture_mismatch"`:
- `override_data { target = data.aws_ami.selected, values = { id = "ami-0123456789abcdef0", architecture = "arm64", root_device_name = "/dev/xvda" } }`
- `expect_failures = [check.ami_architecture]`
- Assertion: the plan still builds the LT: `aws_launch_template.app.instance_type == "t3.micro"`

`run "subnet_outside_vpc"`:
- `override_data { target = data.aws_subnets.in_vpc, values = { ids = ["subnet-0000000000000000a"] } }`
- `expect_failures = [check.subnets_in_vpc]`
- Assertion: `length(aws_db_instance.database) == 0`

#### Scenario: Validation Boundaries (accept)

**Purpose**: Every validation rule accepts its boundary values, so no rule over-rejects.
**File**: `tests/unit_validation.tftest.hcl` (these runs come first in the file)
**Command**: `plan` (mock providers)

In this section, `S(n)` means `join("", [for i in range(n) : "a"])` for n ≤ 1024.

`run "accepts_lower_boundaries"`:
- Inputs:
  - `web.name = "a"`
  - `app = { name = "a", port = 1, health_check_path = "/", health_check_grace_period = 0, min_size = 0, max_size = 1, root_volume_size = 8, managed_policy_arns = {} }`
  - `database = { name = "a", engine_version = "15", allocated_storage = 20, db_name = "a", username = "a", port = 1150, backup_retention_period = 1 }`
  - `vpc` is the fixture. It has exactly 2 public, 2 private and 2 database subnets, which is the minimum for V2, V4 and D1.
- Asserts:
  - `aws_lb.web.name == "a"`
  - `aws_lb_target_group.app.port == 1`
  - `aws_autoscaling_group.app.min_size == 0`
  - `aws_launch_template.app.block_device_mappings[0].ebs[0].volume_size == 8`
  - `aws_db_instance.database[0].port == 1150`
  - `aws_db_instance.database[0].backup_retention_period == 1`
  - `aws_db_instance.database[0].allocated_storage == 20`
  - `aws_db_instance.database[0].engine_version == "15"`

`run "accepts_upper_boundaries"`:
- Inputs:
  - `web.name = S(32)`
  - `app = { name = S(64), port = 65535, health_check_path = format("/%s", S(1023)), user_data = join("", [for i in range(16) : S(1024)]), root_volume_size = 16384, min_size = 2, max_size = 2 }`
  - `database = { name = S(63), allocated_storage = 65536, db_name = S(63), username = S(63), port = 65535, backup_retention_period = 35 }`
- Asserts:
  - `length(aws_lb.web.name) == 32`
  - `aws_autoscaling_group.app.name == S(64)`
  - `length(aws_lb_target_group.app.health_check[0].path) == 1024`
  - `length(base64decode(aws_launch_template.app.user_data)) == 16384`
  - `aws_autoscaling_group.app.max_size == aws_autoscaling_group.app.min_size` (max == min)
  - `aws_db_instance.database[0].backup_retention_period == 35`
  - `aws_db_instance.database[0].allocated_storage == 65536`
  - `length(aws_db_instance.database[0].identifier) == 63`

`run "accepts_alternate_formats"`:
- Inputs:
  - `web = { name = "Web-01", certificate_arn = "arn:aws-us-gov:acm:us-gov-west-1:123456789012:certificate/abc-123", ssl_policy = "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04" }`
  - `app = { instance_type = "m7g.16xlarge", ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/mrk-0123456789abcdef", managed_policy_arns = { custom = "arn:aws-us-gov:iam::123456789012:policy/path/app" } }`
  - `ami = { owners = ["self"], name_pattern = "*" }`
  - `database = { name = "a1-b2", engine_version = "18", instance_class = "db.r7g.large", username = "Svc_Admin_1", kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/mrk-0123456789abcdef", master_user_secret_kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/abc" }`
- No extra override is needed. The fixture's `aws_ec2_instance_type` mock returns `["x86_64"]` for any type, so the arm type does not trip `check.ami_architecture` here. That check has its own negative test in the edge-case file.
- Asserts:
  - `aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04"`
  - `aws_launch_template.app.instance_type == "m7g.16xlarge"`
  - `aws_iam_role_policy_attachment.app["custom"].policy_arn == "arn:aws-us-gov:iam::123456789012:policy/path/app"`
  - `aws_db_instance.database[0].identifier == "a1-b2"`
  - `aws_db_instance.database[0].engine_version == "18"`

`run "accepts_each_allowed_ssl_policy"`:
- Inputs:
  - `web = { certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc", ssl_policy = "ELBSecurityPolicy-TLS13-1-3-2021-06" }`
- Asserts:
  - `aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-3-2021-06"`
  - `aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"`

#### Scenario: Validation Errors (reject)

**Purpose**: Each validation rule rejects its first invalid value. There is one `run` per rule, each with `command = plan` and `expect_failures`.
**File**: `tests/unit_validation.tftest.hcl` (after the accept runs)
**Command**: `plan` (mock providers)

In the table, `vpc(...)` means the fixture `vpc` object with only the named field changed.

| Run | Rule | Input override | `expect_failures` |
|---|---|---|---|
| `reject_vpc_id_format` | V1 | `vpc(vpc_id = "vpc_123")` | `[var.vpc]` |
| `reject_public_subnets_single` | V2 | `vpc(public_subnet_ids = { web-a = "subnet-0000000000000000a" })` | `[var.vpc]` |
| `reject_public_subnet_id_format` | V3 | `vpc(public_subnet_ids = { web-a = "subnet-0000000000000000a", web-b = "sn-2" })` | `[var.vpc]` |
| `reject_private_subnets_single` | V4 | `vpc(private_subnet_ids = { app-a = "subnet-0000000000000001a" })` | `[var.vpc]` |
| `reject_private_subnet_id_format` | V5 | `vpc(private_subnet_ids = { app-a = "subnet-0000000000000001a", app-b = "bad" })` | `[var.vpc]` |
| `reject_database_subnet_id_format` | V6 | `vpc(database_subnet_ids = { db-a = "bad", db-b = "subnet-0000000000000002b" })` | `[var.vpc]` |
| `reject_web_name_too_long` | W1 | `web = { name = S(33) }` | `[var.web]` |
| `reject_web_name_leading_hyphen` | W2 | `web = { name = "-web" }` | `[var.web]` |
| `reject_web_name_internal_prefix` | W3 | `web = { name = "internal-web" }` | `[var.web]` |
| `reject_web_certificate_arn_format` | W4 | `web = { certificate_arn = "arn:aws:iam::123456789012:server-certificate/x" }` | `[var.web]` |
| `reject_web_ssl_policy_legacy` | W5 | `web = { ssl_policy = "ELBSecurityPolicy-2016-08" }` | `[var.web]` |
| `reject_web_ssl_policy_extended` | W5 | `web = { ssl_policy = "ELBSecurityPolicy-TLS13-1-2-Ext1-2021-06" }` | `[var.web]` |
| `reject_app_name_too_long` | A1 | `app = { name = S(65) }` | `[var.app]` |
| `reject_app_name_trailing_hyphen` | A2 | `app = { name = "app-" }` | `[var.app]` |
| `reject_app_instance_type_format` | A3 | `app = { instance_type = "t3micro" }` | `[var.app]` |
| `reject_app_port_zero` | A4 | `app = { port = 0 }` | `[var.app]` |
| `reject_app_port_above_max` | A4 | `app = { port = 65536 }` | `[var.app]` |
| `reject_app_health_check_path_relative` | A5 | `app = { health_check_path = "health" }` | `[var.app]` |
| `reject_app_health_check_path_too_long` | A6 | `app = { health_check_path = format("/%s", S(1024)) }` | `[var.app]` |
| `reject_app_grace_period_negative` | A7 | `app = { health_check_grace_period = -1 }` | `[var.app]` |
| `reject_app_min_size_negative` | A8 | `app = { min_size = -1, max_size = 1 }` | `[var.app]` |
| `reject_app_max_size_zero` | A9 | `app = { min_size = 0, max_size = 0 }` | `[var.app]` |
| `reject_app_max_below_min` | A10 | `app = { min_size = 3, max_size = 2 }` | `[var.app]` |
| `reject_app_root_volume_too_small` | A11 | `app = { root_volume_size = 7 }` | `[var.app]` |
| `reject_app_root_volume_too_large` | A11 | `app = { root_volume_size = 16385 }` | `[var.app]` |
| `reject_app_user_data_too_long` | A12 | `app = { user_data = format("%sb", join("", [for i in range(16) : S(1024)])) }` | `[var.app]` |
| `reject_app_ebs_kms_alias` | A13 | `app = { ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/ebs" }` | `[var.app]` |
| `reject_app_policy_not_arn` | A14 | `app = { managed_policy_arns = { ssm = "AmazonSSMManagedInstanceCore" } }` | `[var.app]` |
| `reject_ami_owners_empty` | M1 | `ami = { owners = [] }` | `[var.ami]` |
| `reject_ami_name_pattern_empty` | M2 | `ami = { name_pattern = "" }` | `[var.ami]` |
| `reject_database_without_database_subnets` | D1 | `vpc(database_subnet_ids = { db-a = "subnet-0000000000000002a" })`, `database = {}` | `[var.database]` |
| `reject_database_name_too_long` | D2 | `database = { name = S(64) }` | `[var.database]` |
| `reject_database_name_double_hyphen` | D3 | `database = { name = "a--b" }` | `[var.database]` |
| `reject_database_name_leading_digit` | D3 | `database = { name = "1db" }` | `[var.database]` |
| `reject_database_engine_version_minor` | D4 | `database = { engine_version = "16.4" }` | `[var.database]` |
| `reject_database_engine_version_below_15` | D5 | `database = { engine_version = "14" }` | `[var.database]` |
| `reject_database_instance_class_prefix` | D6 | `database = { instance_class = "t4g.micro" }` | `[var.database]` |
| `reject_database_storage_too_small` | D7 | `database = { allocated_storage = 19 }` | `[var.database]` |
| `reject_database_storage_too_large` | D7 | `database = { allocated_storage = 65537 }` | `[var.database]` |
| `reject_database_db_name_format` | D8 | `database = { db_name = "1app" }` | `[var.database]` |
| `reject_database_username_format` | D9 | `database = { username = "app-admin" }` | `[var.database]` |
| `reject_database_username_reserved` | D10 | `database = { username = "postgres" }` | `[var.database]` |
| `reject_database_username_reserved_case` | D10 | `database = { username = "Admin" }` | `[var.database]` |
| `reject_database_port_below_min` | D11 | `database = { port = 1149 }` | `[var.database]` |
| `reject_database_backup_zero` | D12 | `database = { backup_retention_period = 0 }` | `[var.database]` |
| `reject_database_backup_above_max` | D12 | `database = { backup_retention_period = 36 }` | `[var.database]` |
| `reject_database_kms_alias` | D13 | `database = { kms_key_arn = "alias/aws/rds" }` | `[var.database]` |
| `reject_database_secret_kms_alias` | D14 | `database = { master_user_secret_kms_key_arn = "alias/secrets" }` | `[var.database]` |

That is 48 reject runs, and every one of the 41 rules is exercised.

### Acceptance Tests

**File**: `tests/acceptance.tftest.hcl`. Every run is marked `# acceptance`. The file uses the real `provider "aws" { region = var.region }` and `command = plan`. The sandbox supplies `TF_VAR_vpc` (real subnet IDs) and `TF_VAR_region`. These tests are not run during this workflow.

#### Scenario: Plan Verification

**Purpose**: Data sources resolve against real AWS, both check blocks pass on real data, and the launch template consumes the resolved values.
**Command**: `plan` (real providers)
**Inputs**: `vpc` from the environment, `web` default, and `database = { deletion_protection = false, skip_final_snapshot = true }`.

`run "plan_resolves_real_data"` asserts:
- AMI resolved: `can(regex("^ami-[0-9a-f]+$", data.aws_ami.selected.id))`
- AMI architecture matches the default type: `data.aws_ami.selected.architecture == "x86_64"`
- LT uses the resolved AMI: `aws_launch_template.app.image_id == data.aws_ami.selected.id`
- Root device from the real AMI: `aws_launch_template.app.block_device_mappings[0].device_name == data.aws_ami.selected.root_device_name`
- AMI output: `output.ami_id == data.aws_ami.selected.id`
- The data tier plans against real subnets: `length(aws_db_subnet_group.database[0].subnet_ids) >= 2`

Both check blocks passing is implicit, because a failing check errors the run.

### Integration Tests

**File**: `tests/integration.tftest.hcl`. Every run is marked `# integration`. The file uses the real provider and `command = apply`, with `TF_VAR_vpc` and `TF_VAR_region` from the sandbox. Resources are destroyed after the run. These tests are not run during this workflow.

#### Scenario: End-to-End

**Purpose**: Resources are created, wired and destroyable.
**Command**: `apply` (real providers)

**Inputs**:

```hcl
web = { name = "tta-int-web" }
app = { name = "tta-int-app", min_size = 1, max_size = 1 }
database = {
  name                    = "tta-int-db"
  multi_az                = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 1
}
```

`run "apply_http_with_database"` asserts:
- ALB ARN format: `can(regex("^arn:aws[a-zA-Z-]*:elasticloadbalancing:", output.alb_arn))`
- ALB DNS: `endswith(output.alb_dns_name, ".elb.amazonaws.com")`
- ASG runs the latest LT version: `aws_autoscaling_group.app.launch_template[0].version == tostring(aws_launch_template.app.latest_version)`
- First LT version: `output.launch_template_latest_version == 1`
- HTTP forwards to the real TG: `aws_lb_listener.http.default_action[0].target_group_arn == aws_lb_target_group.app.arn`
- Secret ARN populated: `can(regex("^arn:aws[a-zA-Z-]*:secretsmanager:", output.db_instance_master_user_secret_arn))`
- Endpoint on the port: `endswith(output.db_instance_endpoint, ":5432")`
- Encrypted in AWS: `aws_db_instance.database[0].storage_encrypted == true`
- Not public in AWS: `aws_db_instance.database[0].publicly_accessible == false`
- SG IDs real: `can(regex("^sg-", output.app_security_group_id))`
- HTTPS output null: `output.https_listener_arn == null`

---

## 6. Implementation Checklist

Items are ordered by dependency. Tests come before resource code (constitution §1.3). No file is touched by more than one item. `examples/basic/` is **not modified** by any item (see §7 deviation 1).

- [x] **A: Scaffold interface.** Rewrite `versions.tf` (`required_version = "~> 1.14"`, aws `~> 5.0`) and `variables.tf` (all 6 variables, 34 fields and 41 validation blocks exactly as in the Interface Contract, `# Required` and `# Optional` groups). Create `locals.tf` (5 locals, each with a why-comment), `main.tf` (`data.aws_ami.selected`) and `check.tf` (both checks, with scoped data sources). Done when `terraform init -backend=false && terraform validate` passes.
- [x] **B: Unit tests first.** Create `tests/unit_basic.tftest.hcl`, `tests/unit_complete.tftest.hcl`, `tests/unit_edge_cases.tftest.hcl` and `tests/unit_validation.tftest.hcl`, each with the shared fixture and the runs above. Delete `tests/validate.tftest.hcl`. Done when `unit_validation` passes in full. The other files fail only on the resources that are still missing.
- [x] **C: Network security core.** Create `vpc.tf`: the three security groups and seven rule resources, each rule with a `description` and a `Name` tag, and `#trivy:ignore:AWS-0104` with its justification above `app_https`. Done when `unit_basic` `network_defaults` passes.
- [x] **D: Web tier.** Create `elb.tf`: `aws_lb.web` (with the AWS-0053 and AWS-0052 ignore comments and their justification), `aws_lb_target_group.app`, the switching `aws_lb_listener.http` (with the AWS-0054 ignore) and `aws_lb_listener.https`. Done when every web assertion in `unit_basic` and `unit_complete`, and `https_without_database`, pass.
- [x] **E: App tier.** Create `iam.tf` (role, profile, attachment `for_each`), `ec2.tf` (launch template) and `autoscaling.tf` (ASG). Done when `app_tier_defaults`, `iam_defaults`, `full_features_app`, `no_managed_policies`, `consumer_name_tag_is_overridden` and both check runs pass.
- [x] **F: Data tier and outputs.** Create `rds.tf` (subnet group and instance) and `outputs.tf` (all 26 outputs, using `try()` for conditional ones). Done when all four unit files pass: `terraform test -filter=tests/unit_basic.tftest.hcl` and the same for the other three files.
- [x] **G: Runnable example.** Create `examples/public-https/` containing:
  - `main.tf`: calls `app.terraform.io/craigsloggett-lab/vpc/aws` version `0.1.0`. Confirm its input names in the private registry before writing. Then calls `source = "../../"` with `vpc = { vpc_id = module.vpc.vpc_id, public_subnet_ids = module.vpc.public_subnet_ids, private_subnet_ids = module.vpc.private_subnet_ids, database_subnet_ids = module.vpc.database_subnet_ids }`, `web.certificate_arn = var.certificate_arn`, unique names, and `database = { deletion_protection = false, skip_final_snapshot = true }` so it destroys cleanly.
  - `providers.tf`: `provider "aws" { region = var.region }` with `default_tags` `ManagedBy`.
  - `versions.tf`: `required_version = "~> 1.14"`, aws exactly `5.100.0`.
  - `variables.tf`: `region`, `certificate_arn`.
  - `outputs.tf`: ALB DNS and the DB secret ARN.
  - `.terraform-docs.yml`.
  - `defaults.auto.tfvars.example`.
  - `README.md`.

  Done when `terraform init -backend=false && terraform validate` passes in the example directory.
- [x] **H: Acceptance and integration tests, then polish.** Create `tests/acceptance.tftest.hcl` and `tests/integration.tftest.hcl` as specified. Regenerate the root `README.md` with terraform-docs. The Usage block still lifts the unchanged `examples/basic/main.tf`. Run `terraform fmt -check -recursive`, `terraform validate`, `terraform test` (unit files), `tflint --recursive` and `trivy config .`. Done when there are no Critical or High findings beyond the five justified inline suppressions (AWS-0177 added during this item).

---

## 7. Open Questions

There are no `[NEEDS CLARIFICATION]` markers. The items below are either deferred follow-ups the user explicitly left out of this release, or constitution deviations recorded for platform-team sign-off (constitution §8.2).

**OQ-1 [DEFERRED] ALB hardening (`drop_invalid_header_fields`, `enable_deletion_protection`).** The user did not select these in clarification Q1, so neither is set.
- **Tension**:
  - Constitution §1.2 requires secure defaults.
  - Security Hub ELB.4 and ELB.6 stay unmet.
  - Trivy AWS-0052 is **HIGH**, and constitution §5.2 blocks release on High findings. The design therefore ships an inline `#trivy:ignore:AWS-0052` with a justification that cites this decision.
- **Recommendation**: Before release, reconsider hardcoding `drop_invalid_header_fields = true`. It has no functional cost for standards-compliant clients and would remove the suppression. The other option is a `web.drop_invalid_header_fields` toggle that defaults to `true`. Deletion protection would conflict with clean example and test teardown unless it is exposed as a toggle.

**OQ-2 [DEFERRED] ALB access logs.** Not selected by the user.
- **Tension**: Constitution §1.2 ("logging MUST be enabled by default") and §7.2. Security Hub ELB.5 stays unmet.
- **Candidate follow-up**: An optional `web.access_logs = optional(object({ bucket = string, prefix = optional(string) }))` object whose presence enables logging. The module would still not create the bucket.

**OQ-3 [DEFERRED] RDS CloudWatch log exports, Performance Insights and Enhanced Monitoring.** Not selected by the user.
- **Tension**: The same constitution rules as OQ-2. Security Hub RDS.9, RDS.36 and RDS.6 stay unmet.
- **Candidate follow-up**:
  - `database.cloudwatch_logs_exports` defaulting to `["postgresql", "upgrade"]`.
  - `database.performance_insights` using the optional CMK already accepted for storage.
  - Enhanced monitoring, which needs a monitoring IAM role.

**OQ-4 [DEFERRED] Narrower app egress.** `app_https` to `0.0.0.0/0:443` is user-directed (Trivy AWS-0104 is suppressed).
- **Candidate follow-up**: An optional `app.egress_prefix_list_ids` input that replaces the CIDR rule when the caller's VPC has endpoints or managed prefix lists.

**OQ-5 [DEFERRED] Post-quantum TLS policies.** The `ssl_policy` allowlist leaves out the 2025 `-PQ-` policies until regional availability and inclusion in the ELB.17 parameter list are confirmed.

**OQ-6 [DEFERRED] Multiple module instances per account and region.** The default names (`three-tier-app-web`, `three-tier-app`, `three-tier-app-db`) collide if the module is instantiated twice without overrides. Callers must set `web.name`, `app.name` and `database.name`. The example and integration test do so.

**[CONSTITUTION DEVIATION] 1: §2.1 example naming and the first-example rule (user-directed).**
- **Rule**: Constitution §2.1 says examples are never named `basic`, and that the README Usage section is the first example's `main.tf`, which must read as consumer usage.
- **Deviation**: At the user's explicit direction, `examples/basic/main.tf` stays **exactly as it is**. It is the registry usage snippet that `.terraform-docs.yml` lifts into the README. It has no provider block, pins registry version `0.0.1` and passes no inputs, so it is not runnable. The runnable, self-contained example is `examples/public-https/`.
- **Risk**: Low. After the first release, the README snippet will not show the required `vpc` input and will not match the published version.
- **Mitigation**: Dependabot bumps the snippet's `version`. `examples/public-https` documents the full usage.

**[CONSTITUTION DEVIATION] 2: §1.2 "security controls MUST be toggleable".**
- **Rule**: Constitution §1.2 says every security control must be toggleable through a variable.
- **Deviation**: These controls are hardcoded:
  - EBS and RDS storage encryption. Only the key is configurable.
  - `publicly_accessible = false`.
  - `manage_master_user_password = true`.
  - IMDSv2.
  - No public IP on app ENIs.
  - IAM database authentication.
  - The PostgreSQL 15+ floor, which enforces TLS.
- **Justification**: None of these has a legitimate "off" state for this module's purpose. Constitution §3.2 itself mandates IMDSv2 on every launch template and forbids public RDS. A caller who needs any of them off needs a different module.
- **Risk**: None to security. It is a flexibility trade-off only.

**[CONSTITUTION DEVIATION] 3: §1.2 and §3.2 encryption in transit when no certificate is supplied (user-directed).**
- **Rule**: Constitution §3.2 requires encryption in transit to be enforced.
- **Deviation**: When `web.certificate_arn` is null, the web tier serves plain HTTP. The user chose this to support environments without a certificate (FR-03). Trivy AWS-0054 is suppressed inline with this justification.
- **Risk**: High (P1) if it is used this way for production traffic.
- **Mitigation**: The runnable example is HTTPS, the input description states the behaviour, and supplying a certificate automatically turns port 80 into a permanent redirect.

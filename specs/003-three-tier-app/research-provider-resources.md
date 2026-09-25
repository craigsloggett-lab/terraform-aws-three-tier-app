## Research: Exact AWS provider 5.x arguments, nested blocks, defaults and gotchas for the three-tier-app resources (with 5.x vs 6.x differences)

### Decision

Target `hashicorp/aws` **5.100.0**, the final 5.x release (registry versions list: `... 5.98.0, 5.99.0, 5.99.1, 5.100.0`; the next line is 6.x, currently 6.66.0). Constrain with `version = "~> 5.0"`, which resolves to 5.100.0. Use only arguments that appear in the 5.100.0 docs. Every resource below uses syntax that is valid in both 5.100.0 and 6.x unless marked **[6.x-only]** or **[removed in 6.x]**.

### Resources Identified

- **Primary Resources**: `aws_lb`, `aws_autoscaling_group`, `aws_db_instance`
- **Supporting Resources**:
  - `aws_lb_listener` (x2 or x3): HTTPS:443 forward, HTTP:80 redirect to 443, or HTTP:80 forward when no cert is supplied
  - `aws_lb_target_group`: instance targets, HTTP health check
  - `aws_launch_template`: IMDSv2, encrypted EBS, instance profile, user data
  - `data.aws_ami`: AMI lookup (always set `owners`)
  - `aws_iam_role`, `aws_iam_instance_profile`, `aws_iam_role_policy_attachment`: EC2 instance role (for example `AmazonSSMManagedInstanceCore`)
  - `aws_db_subnet_group`
  - `aws_security_group` (x3: alb, app, db), with no inline rules
  - `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`: one rule per resource
- **Key Outputs**: `aws_lb.arn`/`dns_name`/`zone_id`/`arn_suffix`; `aws_lb_target_group.arn`/`arn_suffix`; `aws_autoscaling_group.name`/`arn`; `aws_launch_template.id`/`latest_version`; `aws_db_instance.address`/`port`/`endpoint`/`arn`/`identifier`/`master_user_secret[0].secret_arn`; `aws_db_subnet_group.name`; security group `id`s; `aws_iam_role.arn`/`name`
- **Security Considerations**: IMDSv2 (`http_tokens = "required"`, which is NOT the provider default), EBS `encrypted = true` + optional `kms_key_id`, RDS `storage_encrypted = true` (default false), `manage_master_user_password = true` (no password in state), `publicly_accessible = false`, `deletion_protection`, TLS 1.2+/1.3 `ssl_policy` (the provider default `ELBSecurityPolicy-2016-08` is weak), `drop_invalid_header_fields = true` on ALB, security-group-to-security-group references instead of CIDRs for app and db tiers.

---

## 1. `aws_lb` (application, internet-facing)

| Argument | Req | Default | Notes |
|---|---|---|---|
| `name` | opt | auto `tf-lb-*` | **max 32 chars**, alnum + hyphen, cannot start/end with hyphen. Conflicts with `name_prefix` |
| `name_prefix` | opt | – | conflicts with `name` (6-char limit per AWS for LB prefixes) |
| `internal` | opt | `false` | `false` = internet-facing |
| `load_balancer_type` | opt | `"application"` | set explicitly |
| `security_groups` | opt | – | list of SG IDs |
| `subnets` | one of subnets/subnet_mapping | – | public subnets, at least 2 AZs (AWS requirement for ALB) |
| `enable_deletion_protection` | opt | `false` | blocks `terraform destroy` when true |
| `drop_invalid_header_fields` | opt | `false` | security best practice: `true` (Security Hub ELB.4) |
| `enable_http2` | opt | `true` | |
| `idle_timeout` | opt | `60` | |
| `desync_mitigation_mode` | opt | `defensive` | |
| `ip_address_type` | opt | – | `ipv4` / `dualstack` / `dualstack-without-public-ipv4` |
| `access_logs {}` | opt | – | `bucket` (req), `prefix`, `enabled` (**defaults false even when bucket set**) |
| `connection_logs {}` | opt | – | ALB only; same shape |
| `tags` | opt | – | |

- `enable_cross_zone_load_balancing` is always on for ALB and has no effect.
- Attributes: `arn` (= `id`), `arn_suffix` (CloudWatch dimension), `dns_name`, `zone_id`, `tags_all`.
- Timeouts: create/update/delete 10m. Import by ARN.
- **[6.x-only]**: `region`, `health_check_logs {}`, `enable_prefix_for_ipv6_source_nat`, `secondary_ips_auto_assigned_per_subnet`. Do not use them.

## 2. `aws_lb_listener`

Required: `load_balancer_arn` (ForceNew), `default_action {}`.

| Argument | Default | Notes |
|---|---|---|
| `port` | – | number or string; use a number (`443`) |
| `protocol` | `HTTP` (ALB) | `HTTP` / `HTTPS` |
| `certificate_arn` | – | exactly one required when `HTTPS`; extra certs go through `aws_lb_listener_certificate` |
| `ssl_policy` | `ELBSecurityPolicy-2016-08` | required for HTTPS. **Set it explicitly** to `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.2 + 1.3), which is the AWS-recommended default. Do not rely on the provider default |
| `routing_http_response_*` / `routing_http_request_*` | – | optional header controls (HSTS etc.), available in 5.100 |
| `mutual_authentication {}` | – | not needed |
| `tags` | – | |

`default_action` block: `type` (req: `forward`/`redirect`/`fixed-response`/`authenticate-*`), `target_group_arn` (single-TG forward), `forward {}` (weighted), `redirect {}`, `fixed_response {}`, `order`.

`redirect` block: `status_code` **required** (`HTTP_301`/`HTTP_302`), `port` (default `#{port}`), `protocol` (default `#{protocol}`), `host`, `path`, `query` (these three default to their `#{...}` placeholders).

```hcl
# HTTPS forward
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy # "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# HTTP -> HTTPS redirect
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"   # string
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Plain HTTP forward (only when no certificate is supplied)
resource "aws_lb_listener" "http_forward" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

Gotchas:
- Use `count` on the redirect and forward HTTP listeners so exactly one exists (both would conflict on port 80). For example `count = var.certificate_arn != null ? 1 : 0` and the inverse. Do not use a `dynamic` default_action.
- `redirect.port` is a **string**.
- If the certificate is ACM-issued in the same module, depend on `aws_acm_certificate_validation`, not on the certificate itself.
- Attributes: `arn` (= `id`), `tags_all`. The 5.100.0 doc lists no timeouts for the listener.
- **[6.x-only]**: `region`, `default_action.jwt_validation {}`, `timeouts { create, update }`. **[6.x behaviour change]**: `mutual_authentication` sub-args are restricted to `mode = "verify"`. This does not affect us.

## 3. `aws_lb_target_group`

| Argument | Default | Notes |
|---|---|---|
| `name` | random | **max 32 chars**, ForceNew |
| `name_prefix` | – | **max 6 chars**, ForceNew, conflicts with `name` |
| `port` | – | required for `instance`/`ip`; ForceNew |
| `protocol` | – | required for `instance`/`ip`; `HTTP`; ForceNew |
| `protocol_version` | `HTTP1` | ForceNew |
| `vpc_id` | – | required for `instance`/`ip`; ForceNew |
| `target_type` | `instance` | ForceNew; ASG targets are `instance` |
| `deregistration_delay` | `300` | 0–3600; lower it (for example 30–60) for faster instance refresh |
| `slow_start` | `0` | |
| `load_balancing_algorithm_type` | `round_robin` | |
| `stickiness {}` | – | `type` required (`lb_cookie`/`app_cookie`), `enabled` default **true** when the block is present |
| `health_check {}` | – | max 1 block |

`health_check` block (ALB/HTTP): `enabled` (true), `path` (`/`), `port` (`traffic-port`), `protocol` (`HTTP`; TCP not allowed with an HTTP TG), `matcher` (`200`, range 200–499 for ALB), `interval` (30, 5–300), `timeout` (6 for HTTP, 2–120, must be < interval), `healthy_threshold` (3, 2–10), `unhealthy_threshold` (3, 2–10).

Gotchas:
- Because port, protocol, vpc_id and name are ForceNew, a TG attached to a listener cannot be destroyed first. Use `name_prefix` (<= 6 chars) + `lifecycle { create_before_destroy = true }`, or keep the name stable.
- `name` with a long project prefix can exceed 32 characters. Validate or truncate with `substr()`.
- Attributes: `arn` (= `id`), `arn_suffix`, `name`, `load_balancer_arns`.
- **[6.x-only]**: `region`, `target_control_port`. **[6.x change]**: `preserve_client_ip` accepts only `""`/`true`/`false` (irrelevant for ALB).

## 4. `aws_launch_template`

| Argument | Default | Notes |
|---|---|---|
| `name` / `name_prefix` | auto | conflicts; prefer `name_prefix` |
| `image_id` | – | `data.aws_ami.x.id` or `resolve:ssm:/aws/service/...` |
| `instance_type` | – | conflicts with `instance_requirements` |
| `vpc_security_group_ids` | – | list; **conflicts with `network_interfaces.security_groups`**. Do not add a `network_interfaces` block with SGs |
| `iam_instance_profile {}` | – | `name` **or** `arn` (they conflict). Use `arn = aws_iam_instance_profile.x.arn` or `name = ...name` |
| `user_data` | – | **must already be base64**: `base64encode(templatefile(...))` or `filebase64()`. There is no `user_data_base64` on the launch template |
| `metadata_options {}` | – | `http_endpoint` (default `enabled`), **`http_tokens` default `optional`, so set `required`**, `http_put_response_hop_limit` (default 1; use 1 for EC2, 2 if containers need IMDS), `instance_metadata_tags` (`enabled`/`disabled`), `http_protocol_ipv6` |
| `block_device_mappings {}` | – | `device_name` (req; must match AMI root, for example AL2023 `/dev/xvda`; read from `data.aws_ami.x.root_device_name`), `ebs {}` |
| `ebs {}` | – | `volume_size`, `volume_type` (`gp3`), `encrypted` (bool; **cannot be combined with `snapshot_id`**), `kms_key_id` (**ARN**; requires `encrypted = true`), `delete_on_termination`, `iops`, `throughput` (gp3) |
| `monitoring { enabled }` | – | detailed monitoring |
| `update_default_version` | – | conflicts with `default_version`; set `true` so `$Default` tracks changes |
| `tag_specifications {}` | – | repeatable; `resource_type` (`instance`, `volume`, `network-interface`, ...) + `tags` map |
| `tags` | – | tags the template itself only |

Gotchas:
- Provider `default_tags` are **not** propagated to instances or volumes launched by an ASG through the launch template (provider issue #32328). Add `tag_specifications` for `instance` and `volume` with `merge(var.tags, {Name = ...})`.
- `kms_key_id` in `ebs` must be a key **ARN**. When a CMK is used with ASG, the ASG service-linked role (`AWSServiceRoleForAutoScaling`) must be allowed in the key policy or grants, or launches fail with `Client.InternalError`.
- Attributes: `arn`, `id`, `latest_version`, `default_version`, `tags_all`. No timeouts. Import by `lt-...` id.
- **[removed in 6.x]**: `elastic_gpu_specifications`, `elastic_inference_accelerator`. Do not use them. **[6.x change]**: `ebs.encrypted`, `ebs.delete_on_termination`, `ebs_optimized`, `network_interfaces.associate_public_ip_address` accept only `true`/`false`/`""` (not `0`/`1`). Use real booleans. **[6.x-only]**: `region`, several newer network-interface args.

## 5. `aws_autoscaling_group`

| Argument | Req | Default | Notes |
|---|---|---|---|
| `min_size`, `max_size` | **req** | – | |
| `desired_capacity` | opt | – | often `lifecycle { ignore_changes = [desired_capacity] }` when scaling policies exist |
| `name` / `name_prefix` | opt | generated | |
| `vpc_zone_identifier` | opt | – | private app subnets; **conflicts with `availability_zones`** |
| `launch_template {}` | one of launch_template / mixed_instances_policy / launch_configuration | – | `id` **or** `name` (conflict), `version` (default **`$Default`**) |
| `health_check_type` | opt | `EC2` | `"ELB"` so ALB health checks drive replacement |
| `health_check_grace_period` | opt | `300` | docs note: required when type is ELB (it has a default, so set it explicitly) |
| `target_group_arns` | opt | – | set of TG ARNs. See below |
| `traffic_source {}` | opt | – | `identifier`, `type` (`elbv2`) |
| `min_elb_capacity` / `wait_for_elb_capacity` | opt | – | makes apply wait for healthy targets |
| `wait_for_capacity_timeout` | opt | `"10m"` | `"0"` disables waiting |
| `instance_refresh {}` | opt | – | see below |
| `instance_maintenance_policy {}` | opt | – | `min_healthy_percentage`, `max_healthy_percentage` (both req) |
| `default_instance_warmup` | opt | – | |
| `termination_policies`, `enabled_metrics`, `metrics_granularity` (`1Minute`) | opt | | |
| `protect_from_scale_in`, `max_instance_lifetime`, `force_delete` | opt | | |
| `tag {}` | opt | – | repeatable; `key`, `value`, `propagate_at_launch` **all required** |

`instance_refresh` block: `strategy = "Rolling"` (req, only value), `triggers` (set; `launch_template` changes always trigger), `preferences { min_healthy_percentage (90), max_healthy_percentage (100, range 100–200), instance_warmup, skip_matching (false), auto_rollback (false; LT only), checkpoint_percentages, checkpoint_delay (3600), scale_in_protected_instances (Ignore), standby_instances (Ignore), alarm_specification { alarms } }`.

Gotchas:
- **Instance refresh does not start with `version = "$Latest"`**. Use `version = aws_launch_template.x.latest_version`.
- Terraform does not wait for the refresh to finish. Only one refresh can be active at a time, and a new apply cancels the running one.
- **target_group_arns vs `aws_autoscaling_traffic_source_attachment` / `aws_autoscaling_attachment`**: never attach the same TG through more than one mechanism, or you get perpetual diffs and detach/attach flapping. For a single module that owns both the ASG and the TG, **inline `target_group_arns = [aws_lb_target_group.app.arn]` is simplest and valid in 5.x and 6.x**. Use the standalone `aws_autoscaling_traffic_source_attachment` (`autoscaling_group_name`, `traffic_source { identifier = tg_arn, type = "elbv2" }`, no exported attributes) only if TGs are added outside the ASG lifecycle. Then set `lifecycle { ignore_changes = [target_group_arns, traffic_source] }` on the ASG.
- `tag` blocks: use `dynamic "tag"` over `merge(var.tags, {Name = ...})` with `propagate_at_launch = true`. Launch-template `tag_specifications` and ASG `propagate_at_launch` tags overlap. Pick one source for instance tags (ASG tags win on key conflicts at launch).
- `health_check_type = "ELB"` with a bad health-check path leads to endless replacement. Size `health_check_grace_period` to boot + user_data time.
- Attributes: `id` (= name), `arn`, `name`, `availability_zones`, `predicted_capacity`, `warm_pool_size`. Timeouts: delete 10m only. Import by name.
- **[6.x-only]**: `region`, `instance_lifecycle_policy {}` (`retention_triggers`, `terminate_hook_abandon`), `timeouts.update`. Do not use them.

## 6. `data "aws_ami"`

Arguments: `owners` (list; `"amazon"`, account IDs, `self`), `most_recent` (bool), `filter { name, values }` (repeatable, EC2 DescribeImages filters), `name_regex`, `include_deprecated` (false), `executable_users`.

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

Gotchas:
- More or fewer than exactly one match fails unless `most_recent = true`.
- **[5.x warning, 6.x error]**: `most_recent = true` without `owners` (or an `owner-id`/`image-id` filter) is only a warning in 5.x and a hard error in 6.x. **Always set `owners`** so the config is forward compatible. `allow_unsafe_filter` is **[6.x-only]**.
- `most_recent` means the AMI changes over time, which changes the LT and triggers an instance refresh. Consider an `ami_id` override variable or `ignore_changes`, or SSM `resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` in `image_id`.
- Useful attributes: `id`, `root_device_name`, `architecture`, `imds_support` (`v2.0` if the AMI enforces IMDSv2).

## 7. IAM: `aws_iam_role`, `aws_iam_instance_profile`, `aws_iam_role_policy_attachment`

`aws_iam_role`: `assume_role_policy` (**required**; use `data.aws_iam_policy_document` with principal `ec2.amazonaws.com`), `name`/`name_prefix` (ForceNew; `name_prefix` max 38 chars per IAM), `path`, `description`, `max_session_duration`, `permissions_boundary`, `force_detach_policies` (false), `tags`. Attributes: `arn`, `id` (= name), `name`, `unique_id`, `create_date`.

- **`inline_policy` and `managed_policy_arns` are Deprecated in 5.100.0 (still deprecated, not removed, in 6.x).** When set, they take **exclusive** ownership of that policy type and conflict with `aws_iam_role_policy_attachment` / `aws_iam_role_policy` / `aws_iam_policy_attachment`, causing perpetual diffs and flapping. **Do not set either.** Use `aws_iam_role_policy_attachment` (managed) and `aws_iam_role_policy` (inline). Add `aws_iam_role_policy_attachments_exclusive` / `aws_iam_role_policies_exclusive` only if you need exclusivity (both exist in 5.100.0).

`aws_iam_instance_profile`: `name`/`name_prefix` (ForceNew; name must be account-unique regardless of path), `path` ("/"), `role` (role **name**), `tags`. Attributes: `arn`, `id`, `unique_id`. Reference it from the LT through `iam_instance_profile { arn = ... }`.

`aws_iam_role_policy_attachment`: `role` (role **name**, req), `policy_arn` (req). No attributes. Use `for_each = toset(var.managed_policy_arns)` and build ARNs with `data.aws_partition.current.partition` (for example `arn:${partition}:iam::aws:policy/AmazonSSMManagedInstanceCore`).

- Gotcha: IAM is eventually consistent. A newly created instance profile can briefly be "invalid" for EC2 launches. ASG retries, so this is usually harmless.
- **[6.x-only]**: `account_id` (appears only in the 6.x resource identity section, not as an argument).

## 8. `aws_db_instance` (postgres)

| Argument | Default | Notes |
|---|---|---|
| `identifier` / `identifier_prefix` | random | conflict |
| `engine` | – | `"postgres"` (req) |
| `engine_version` | latest | prefix like `"16"` allowed with `auto_minor_version_upgrade = true`; actual version in `engine_version_actual` |
| `instance_class` | – | **req**, for example `db.t4g.micro` |
| `allocated_storage` | – | **req** (GiB); `max_allocated_storage` enables autoscaling (diffs on allocated_storage then suppressed) |
| `storage_type` | `gp2` (or `io1` when iops) | set `gp3` |
| `storage_encrypted` | **`false`** | set `true` |
| `kms_key_id` | AWS-managed `aws/rds` | **ARN** required; ForceNew in practice (cannot change encryption key in place) |
| `db_name` | none | initial database (the old `name` arg was removed in 5.0) |
| `username` | – | req (unless snapshot/replica) |
| `manage_master_user_password` | – | `true` = RDS stores the password in Secrets Manager. **Cannot be set together with `password` / `password_wo`** |
| `master_user_secret_kms_key_id` | `aws/secretsmanager` | key ARN, key ID, alias ARN or alias name |
| `password` / `password_wo` + `password_wo_version` | – | not used; `password_wo` is write-only and needs TF >= 1.11 (present in 5.100.0) |
| `multi_az` | false | |
| `db_subnet_group_name` | `default` subnet group | pass `aws_db_subnet_group.x.name` (else it lands in the default VPC) |
| `vpc_security_group_ids` | – | DB SG |
| `publicly_accessible` | `false` | keep false |
| `port` | engine default 5432 | |
| `backup_retention_period` | **`0`** (in provider doc; RDS API default is 1) | 0–35; set >= 7 (Security Hub RDS.11) |
| `backup_window` / `maintenance_window` | – | must not overlap |
| `deletion_protection` | `false` | |
| `skip_final_snapshot` | **`false`** | when false, **`final_snapshot_identifier` must be set** or destroy fails |
| `final_snapshot_identifier` | – | letter-first, alnum/hyphen, no trailing or double hyphen |
| `copy_tags_to_snapshot` | false | set true |
| `delete_automated_backups` | true | |
| `apply_immediately` | false | |
| `auto_minor_version_upgrade` | true | |
| `iam_database_authentication_enabled` | – | |
| `performance_insights_enabled` / `_kms_key_id` / `_retention_period` | false / – / 7 | |
| `monitoring_interval` / `monitoring_role_arn` | 0 | enhanced monitoring |
| `enabled_cloudwatch_logs_exports` | – | postgres: `["postgresql", "upgrade"]` |
| `parameter_group_name` | default | e.g. to force `rds.force_ssl = 1` (the pg15+ default is already 1) |
| `ca_cert_identifier` | – | |
| `tags` | | |

Attributes: `address`, `endpoint` (`host:port`), `port`, `arn`, `id` (**in 5.x `id` is the DBI resource ID, not the identifier**; use `identifier` for the name), `resource_id`, `hosted_zone_id`, `engine_version_actual`, `status`, `multi_az`, `storage_encrypted`, `username`, and **`master_user_secret`**: a *list* block (reference `aws_db_instance.x.master_user_secret[0].secret_arn`) with `kms_key_id`, `secret_arn`, `secret_status`. It exists only when `manage_master_user_password = true`, so guard it: `try(aws_db_instance.x.master_user_secret[0].secret_arn, null)`.

Gotchas:
- A non-deterministic `final_snapshot_identifier` (such as `timestamp()`) causes perpetual diffs. Use a static `"${var.name}-final"`, or combine `skip_final_snapshot` with a variable.
- `deletion_protection = true` blocks destroy (including in `terraform test`). Expose it as a variable and set it false in tests.
- `kms_key_id` must be an ARN (a key ID leads to a perpetual diff).
- Timeouts: create 40m, update 80m, delete 60m. Import by `identifier`.
- **[6.x change]**: `character_set_name` is invalid with `replicate_source_db`, `restore_to_point_in_time`, `s3_import` or `snapshot_identifier` (does not apply to postgres). **[6.x-only]**: `region`, `upgrade_rollout_order`, `warning_event_categories`, and a `replicas` attribute.

## 9. `aws_db_subnet_group`

`name`/`name_prefix` (ForceNew; name must be lowercase), `subnet_ids` (**req**, at least 2 AZs per RDS), `description` (default "Managed by Terraform"), `tags`. Attributes: `id` (= name), `name`, `arn`, `vpc_id`, `supported_network_types`. **[6.x-only]**: `region`.

## 10. `aws_security_group` + `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`

`aws_security_group`: `name`/`name_prefix` (ForceNew), `description` (ForceNew, default "Managed by Terraform", cannot be `""`), `vpc_id` (ForceNew; defaults to the **default VPC**, so always set it), `revoke_rules_on_delete` (false), `tags`. **Do not set `ingress`/`egress` inline blocks** when using the standalone rule resources, because mixing them causes rule overwrites and perpetual diffs. Terraform removes the AWS default allow-all egress on create, so every SG needs explicit egress rules. Attributes: `id`, `arn`, `owner_id`. Timeouts: create 10m, delete 15m. Use `name_prefix` + `create_before_destroy` to avoid the "SG deletion problem" on replacement.

Rule resources (same schema for ingress and egress):

| Argument | Notes |
|---|---|
| `security_group_id` | **req** |
| `ip_protocol` | **req on ingress**, optional on egress (always set it). `"tcp"`, `"udp"`, `"icmp"`, or `"-1"` (all). With `-1`, **do not set** `from_port`/`to_port` |
| `from_port` / `to_port` | required unless `ip_protocol` is `-1` or `icmpv6` |
| exactly one of `cidr_ipv4`, `cidr_ipv6`, `prefix_list_id`, `referenced_security_group_id` | each rule takes **one** CIDR (not a list); use `for_each` over CIDRs |
| `description`, `tags` | |

Attributes: `arn`, `security_group_rule_id`, `tags_all`. Import by `sgr-...`.

Tier pattern:
- ALB SG: ingress 443 (and 80) from `cidr_ipv4 = "0.0.0.0/0"` (or `var.allowed_cidrs`, one rule each); egress app port with `referenced_security_group_id = app_sg`.
- App SG: ingress app port from `referenced_security_group_id = alb_sg`; egress 5432 to `db_sg`; egress 443 to `0.0.0.0/0` (SSM, package repos, or VPC endpoints).
- DB SG: ingress 5432 from `referenced_security_group_id = app_sg`; no egress rules needed (stateful return traffic).

These cross-references (alb references app, app references db) are **not** cycles, because the rules are separate resources from the SGs.

- **[6.x-only]**: `region`. The 6.x docs also add an `id` attribute on rule resources, so reference `security_group_rule_id`, which works in both.

---

## Consolidated 5.x vs 6.x compatibility checklist (avoid 6.x-only syntax)

| Item | 5.100.0 | 6.x | Action |
|---|---|---|---|
| Per-resource `region` argument | absent | present on nearly all resources | never set `region` on resources |
| `data.aws_ami` `most_recent` without `owners` | warning | **error** | always set `owners` |
| `data.aws_ami` `allow_unsafe_filter` | absent | present | do not use |
| `aws_launch_template` `elastic_gpu_specifications` / `elastic_inference_accelerator` | deprecated | **removed** | do not use |
| Nullable bool args (`ebs.encrypted`, `ebs.delete_on_termination`, `ebs_optimized`, `associate_public_ip_address`, TG `preserve_client_ip`) | accept 0/1 | only true/false/"" | use booleans |
| `aws_lb_listener` `jwt_validation`, `timeouts{}` | absent | present | do not use |
| `aws_lb_listener` mutual_authentication rules | loose | stricter | not used |
| `aws_lb` `health_check_logs`, `enable_prefix_for_ipv6_source_nat`, `secondary_ips_auto_assigned_per_subnet` | absent | present | do not use |
| `aws_lb_target_group` `target_control_port` | absent | present | do not use |
| `aws_autoscaling_group` `instance_lifecycle_policy`, `timeouts.update` | absent | present | do not use |
| `aws_db_instance` `upgrade_rollout_order`, `warning_event_categories` | absent | present | do not use |
| `aws_iam_role` `inline_policy` / `managed_policy_arns` | deprecated | deprecated | do not use; use attachment resources |
| `aws_instance.user_data` hashing (not used here) | hashed | cleartext | N/A (the LT `user_data` is base64 in both) |

Everything else used in this design (all arguments in sections 1–10 not marked 6.x-only) has identical names and semantics in 5.100.0 and 6.66.0, per a scripted diff of the argument lists in both doc versions.

### Rationale

- The version was found by querying the Terraform Registry versions API (`/v1/providers/hashicorp/aws/versions`): the highest 5.x is `5.100.0`. The MCP `search_providers`/`get_provider_details` calls with `provider_version = 5.100.0` returned the doc IDs used (lb 9211294, lb_listener 9211296, lb_target_group 9211300, launch_template 9211293, autoscaling_group 9210620, autoscaling_traffic_source_attachment 9210626, db_instance 9210866, db_subnet_group 9210877, iam_role 9211177, iam_instance_profile 9211172, iam_role_policy_attachment 9211180, security_group 9211728, ingress_rule 9211942, egress_rule 9211941, data ami 9209890).
- The 5.x vs 6.x differences come from the official Version 6 Upgrade Guide (doc 13746811) plus a diff of argument bullets between `v5.100.0` and `v6.66.0` tags of `website/docs/` in `hashicorp/terraform-provider-aws`.
- The provider docs themselves call standalone SG rule resources and IAM attachment resources "current best practice" and mark inline SG rules and `managed_policy_arns`/`inline_policy` as legacy or deprecated.
- Security defaults follow AWS guidance: IMDSv2 required (EC2 User Guide), ELB TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (ALB HTTPS listener docs), RDS encryption, Secrets Manager-managed master password, no public access, backups >= 7 days (AWS Security Hub FSBP controls EC2.8, ELB.4, RDS.2/3/11/8, ELB.1).

### Alternatives Considered

| Alternative | Why Not |
|---|---|
| Inline `ingress`/`egress` on `aws_security_group` / `aws_security_group_rule` | Provider docs mark them legacy (no unique IDs, multi-CIDR problems); mixing with standalone rules corrupts state |
| `managed_policy_arns` / `inline_policy` on `aws_iam_role` | Deprecated in 5.x; exclusive ownership conflicts with attachment resources |
| `aws_autoscaling_traffic_source_attachment` / `aws_autoscaling_attachment` | Valid, but needs `ignore_changes` on the ASG; inline `target_group_arns` is simpler when the module owns both ASG and TG |
| `launch_template.version = "$Latest"` | Does not trigger instance refresh; use `latest_version` |
| `password` / `password_wo` on RDS | Plaintext in state (`password`) or needs TF 1.11 plus external secret handling; `manage_master_user_password` keeps it out of Terraform entirely |
| `aws_launch_configuration` | Deprecated by AWS (no new instance types); launch templates required for IMDSv2 and refresh features |
| Pinning `~> 6.0` | Requirement is explicitly 5.x |

### Sources

- Terraform Registry versions API: https://registry.terraform.io/v1/providers/hashicorp/aws/versions (5.100.0 = latest 5.x; 6.66.0 = latest 6.x at research time)
- Provider docs v5.100.0: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/lb, `lb_listener`, `lb_target_group`, `launch_template`, `autoscaling_group`, `autoscaling_traffic_source_attachment`, `iam_role`, `iam_instance_profile`, `iam_role_policy_attachment`, `db_instance`, `db_subnet_group`, `security_group`, `vpc_security_group_ingress_rule`, `vpc_security_group_egress_rule`, data source `ami`
- Version 6 upgrade guide: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade
- Doc source diff: https://github.com/hashicorp/terraform-provider-aws/tree/v5.100.0/website/docs vs `/tree/v6.66.0/website/docs`
- Provider issue on default_tags not propagating to ASG instances: https://github.com/hashicorp/terraform-provider-aws/issues/32328
- AWS ALB HTTPS listener security policies: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html
- AWS IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS ASG instance refresh: https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html
- AWS RDS + Secrets Manager: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html
- AWS Security Hub FSBP controls: https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html

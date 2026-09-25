## Research: AWS security and reliability best practices (Well-Architected, Security Hub FSBP / CIS) for a three-tier ALB + EC2 ASG + RDS PostgreSQL module

### Decision

Build secure defaults directly into the module. That means an HTTPS listener pinned to a TLS 1.3-capable policy (default `ELBSecurityPolicy-TLS13-1-2-2021-06`), an HTTP listener that only does a 301 redirect, a launch template with IMDSv2, no public IP and encrypted EBS, a multi-AZ ASG that uses ELB health checks, and a multi-AZ, encrypted, non-public RDS PostgreSQL with deletion protection and an RDS-managed Secrets Manager password. Security groups are chained by SG ID using standalone rule resources. The Security Hub controls this iteration leaves unmet by design (ELB.4, ELB.5, ELB.6, RDS.9, RDS.36 and others) are listed below so `design.md` can record them.

### Resources Identified

- **Primary Resources**: `aws_lb` (ALB), `aws_autoscaling_group`, `aws_db_instance` (engine `postgres`)
- **Supporting Resources**:
  - `aws_lb_listener` (HTTPS :443, forward) — `ssl_policy`, `certificate_arn`
  - `aws_lb_listener` (HTTP :80) — `default_action { type = "redirect" redirect { protocol = "HTTPS" port = "443" status_code = "HTTP_301" } }`
  - `aws_lb_target_group` — HTTP health check on the app port and path
  - `aws_launch_template` — `metadata_options`, `network_interfaces`, `block_device_mappings`, `iam_instance_profile`
  - `aws_iam_role`, `aws_iam_instance_profile`, `aws_iam_role_policy_attachment` (for_each, default `AmazonSSMManagedInstanceCore`)
  - `aws_db_subnet_group` — DB subnets (at least 2 AZs, required for Multi-AZ)
  - `aws_security_group` x3 (alb, app, db) plus `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`
  - Optional: `aws_db_parameter_group` (pins `rds.force_ssl = 1` explicitly; it is already the default for PG 15+)
- **Key Arguments**:
  - ALB: `internal = false`, `subnets` (public, 2 or more AZs), `desync_mitigation_mode = "defensive"` (default; satisfies ELB.12), `drop_invalid_header_fields = false` (not requested, leaves ELB.4 open), `enable_deletion_protection = false` (not requested, leaves ELB.6 open)
  - Listener: `ssl_policy` default `ELBSecurityPolicy-TLS13-1-2-2021-06`. The provider default is `ELBSecurityPolicy-2016-08`, which allows TLS 1.0/1.1 and fails ELB.17, so the module must always set this.
  - Launch template: `metadata_options { http_tokens = "required", http_endpoint = "enabled", http_put_response_hop_limit = 1 }`, `network_interfaces { associate_public_ip_address = false, security_groups = [app] }`, `block_device_mappings { ebs { encrypted = true, kms_key_id = var.ebs_kms_key_arn } }`
  - ASG: `vpc_zone_identifier` (private subnets, 2 or more AZs), `health_check_type = "ELB"`, `health_check_grace_period`, `target_group_arns`, `launch_template { id, version = "$Latest" }`, optional `instance_refresh`
  - RDS: `storage_encrypted = true`, `kms_key_id` (null means the `aws/rds` key), `publicly_accessible = false`, `multi_az = true`, `backup_retention_period = 7`, `deletion_protection = true`, `skip_final_snapshot = false` plus `final_snapshot_identifier`, `auto_minor_version_upgrade = true`, `copy_tags_to_snapshot = true`, `manage_master_user_password = true`, `master_user_secret_kms_key_id` (null means `aws/secretsmanager`), `iam_database_authentication_enabled = true` (recommended; costs nothing and satisfies RDS.10), `username` not `postgres` (RDS.25), `port` (5432 fails RDS.23; see below), `enabled_cloudwatch_logs_exports = []` (not requested)
- **Key Outputs**: `alb_arn`, `alb_dns_name`, `alb_zone_id`, `target_group_arn`, `autoscaling_group_name`, `launch_template_id`, `instance_role_arn`, `db_instance_arn`, `db_instance_address`, `db_instance_port`, `db_master_user_secret_arn` (`aws_db_instance.this.master_user_secret[0].secret_arn`), the three security group IDs (all `string`)
- **Security Considerations**: TLS 1.2+ only at the edge, HTTP used only for redirect, IMDSv2, no public IPs on app or DB, encryption at rest everywhere (with optional CMKs), no plaintext DB password in state, least-privilege SG chaining, SSM Session Manager instead of SSH (no port 22 ingress)

---

### 1. ALB TLS security policy names (HTTPS listener)

AWS ELB docs ("Security policies for your Application Load Balancer") list these TLS 1.3 policies:

| Policy | Protocols | Notes |
| --- | --- | --- |
| `ELBSecurityPolicy-TLS13-1-2-2021-06` | TLS 1.2, 1.3 | **AWS-recommended default** (console default). Recommended module default. |
| `ELBSecurityPolicy-TLS13-1-2-Res-2021-06` | TLS 1.2, 1.3 | Restricted: AEAD/ECDHE ciphers only. Use when there are no legacy clients. |
| `ELBSecurityPolicy-TLS13-1-3-2021-06` | TLS 1.3 only | Strictest. Can break older clients. |
| `ELBSecurityPolicy-TLS13-1-2-Ext1-2021-06` / `-Ext2-2021-06` | TLS 1.2, 1.3 | Extended (CBC/legacy) ciphers. Do not allow. |
| `ELBSecurityPolicy-TLS13-1-1-2021-06` / `-1-0-2021-06` | TLS 1.0/1.1+ | Legacy. Do not allow. |
| `ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`, `-1-2-Res-FIPS-2023-04`, `-1-3-FIPS-2023-04` | FIPS variants | Allow for FedRAMP/FIPS consumers. |
| `ELBSecurityPolicy-TLS13-1-2-PQ-2025-09`, `-1-2-Res-PQ-2025-09`, `-1-3-PQ-2025-09` (and FIPS-PQ variants) | Hybrid post-quantum key exchange | Newer (2025). Check that the region and the ELB.17 parameter list include them before allowing. |

**Security Hub ELB.17** ("Application and Network Load Balancers with listeners should use recommended security policies") passes only when the policy is on its `sslPolicies` list. The default list is built from the TLS13-1-2 (standard, Res, FIPS) and TLS13-1-3 policies above. Recommended variable validation: `can(regex("^ELBSecurityPolicy-TLS13-1-(2|3)-", var.ssl_policy)) && !can(regex("-Ext[12]-", var.ssl_policy))`.

Optional hardening on the HTTPS listener: `routing_http_response_strict_transport_security_header_value` (HSTS). This was added in later 5.x provider versions; if the `~> 5.0` floor is kept, check the version before using it.

### 2. HTTP to HTTPS redirect

- **Security Hub ELB.1** ("Application Load Balancer should be configured to redirect all HTTP requests to HTTPS") is satisfied when every HTTP listener's default action is a redirect to HTTPS. Use `HTTP_301`, and do not add forward rules on the :80 listener.
- **ELB.18** ("ALB and NLB listeners should use secure protocols to encrypt data in transit") checks the listener protocol. Depending on how Security Hub evaluates it, a :80 redirect-only listener may be reported. Record this as a known or accepted finding (the redirect is the AWS-documented pattern), or make the HTTP listener optional (`create_http_redirect_listener = true`).

### 3. Security Hub controls: ALB (ELB.x)

| Control | Requirement | Module status |
| --- | --- | --- |
| ELB.1 | HTTP to HTTPS redirect | **Met** (redirect listener) |
| ELB.4 | ALB drops invalid HTTP headers (`drop_invalid_header_fields = true`) | **Not met** (not requested) |
| ELB.5 | ALB access logging enabled | **Not met** (not requested) |
| ELB.6 | ALB deletion protection enabled | **Not met** (not requested) |
| ELB.12 | Desync mitigation `defensive` or `strictest` | **Met** (provider/API default `defensive`; do not set `monitor`) |
| ELB.13 | ALB spans 2 or more AZs | **Met** if at least 2 public subnets in different AZs (validate `length(var.public_subnet_ids) >= 2`) |
| ELB.16 | ALB associated with AWS WAF web ACL (NIST 800-53 standard) | **Not met** (out of scope) |
| ELB.17 | Recommended TLS security policy | **Met** with the TLS13 default and validation |
| ELB.18 | Listeners use secure protocols | **Partial**: the HTTPS listener passes; the :80 redirect listener may be reported |
| ELB.21 / ELB.22 (2025) | Target group health checks / traffic use encrypted protocols | **Not met**: ALB to instance uses HTTP. This is TLS offload at the ALB, the common and accepted pattern. |
| ELB.2 / 3 / 7 / 8 / 9 / 10 / 14 | Classic Load Balancer only | N/A |

### 4. Security Hub controls: EC2

| Control | Requirement | Module status |
| --- | --- | --- |
| EC2.8 | Instances use IMDSv2 | **Met** (`http_tokens = "required"` in the launch template) |
| EC2.170 | Launch templates use IMDSv2 | **Met** |
| EC2.9 | Instances have no public IPv4 | **Met** (private subnets plus `associate_public_ip_address = false`) |
| EC2.25 | Launch templates do not assign public IPs to ENIs | **Met** (explicit `false` in `network_interfaces`) |
| EC2.3 | Attached EBS volumes encrypted | **Met** (`encrypted = true`; CMK optional) |
| EC2.7 | EBS encryption by default (account setting) | Out of scope (account level) |
| EC2.13 / 14 / 53 / 54 | No 0.0.0.0/0 or ::/0 ingress to 22/3389/admin ports | **Met** (no SSH; SSM is used) |
| EC2.18 | Unrestricted ingress only on authorized ports (default 80, 443) | **Met** (ALB SG opens only 80 and 443 to the world) |
| EC2.19 | No unrestricted access to high-risk ports | **Met** |
| EC2.17 | Instances do not use multiple ENIs | **Met** (single ENI) |
| EC2.28 | EBS volumes covered by a backup plan | **Not met** (stateless app tier; out of scope) |
| EC2.2 / EC2.15 / EC2.6 | Default SG, subnet auto-assign public IP, VPC flow logs | Out of scope (VPC is supplied by the consumer) |
| SSM.1 | Instances managed by Systems Manager | **Met** if the AMI has the SSM agent, `AmazonSSMManagedInstanceCore` is attached, and there is HTTPS egress (or SSM VPC endpoints) |

### 5. Security Hub controls: Auto Scaling

| Control | Requirement | Module status |
| --- | --- | --- |
| AutoScaling.1 | ASG with a load balancer uses ELB health checks | **Met** (`health_check_type = "ELB"`) |
| AutoScaling.2 | ASG spans multiple AZs | **Met** (validate at least 2 private subnets) |
| AutoScaling.3 | Launch *configurations* require IMDSv2 | N/A (launch template used; EC2.170 covers this) |
| AutoScaling.5 | Launch *configuration* instances have no public IP | N/A (launch template; EC2.25 covers this) |
| AutoScaling.6 | ASG uses multiple instance types in multiple AZs | **Not met** unless `mixed_instances_policy` is used. Single `instance_type` is the simpler design, so record this as accepted. |
| AutoScaling.9 | ASG uses launch templates | **Met** |
| AutoScaling.10 | ASGs tagged (AWS Resource Tagging standard) | Met if tags are passed (`tag` blocks with `propagate_at_launch = true`) |

Reliability (Well-Architected REL10/REL11): `min_size >= 2` across 2 or more AZs, a target group health check path, a `health_check_grace_period` sized to boot time, and `instance_refresh { strategy = "Rolling" }` so launch template changes roll out.

### 6. Security Hub controls: RDS (PostgreSQL DB instance)

| Control | Requirement | Module status |
| --- | --- | --- |
| RDS.2 | Not publicly accessible | **Met** (`publicly_accessible = false`, DB subnets) |
| RDS.3 | Storage encrypted | **Met** (`storage_encrypted = true`, `kms_key_id` optional) |
| RDS.4 | Snapshots encrypted | **Met** (inherited from an encrypted instance) |
| RDS.5 | Multi-AZ | **Met** (`multi_az = true`) |
| RDS.6 | Enhanced Monitoring configured | **Not met** unless `monitoring_interval > 0` plus a monitoring role. Not in the clarified scope, so record it. |
| RDS.8 | Deletion protection | **Met** (`deletion_protection = true`) |
| RDS.9 | Logs published to CloudWatch Logs | **Not met** (log exports not requested) |
| RDS.10 | IAM authentication configured | **Met if** `iam_database_authentication_enabled = true` (recommended default) |
| RDS.11 | Automatic backups enabled (parameter `backupRetentionMinimum` default 7) | **Met** (7 days) |
| RDS.13 | Auto minor version upgrade | **Met** (`true`) |
| RDS.17 | Copy tags to snapshots | **Met** (`copy_tags_to_snapshot = true`) |
| RDS.18 | Instance deployed in a VPC | **Met** |
| RDS.19 / 20 / 21 / 22 | RDS event notification subscriptions | **Not met** (no `aws_db_event_subscription`; out of scope) |
| RDS.23 | Not using the engine default port | **Not met** with 5432. Either default `db_port` to a non-default value (for example 5433), which also changes the app-to-DB SG rule, or keep 5432 and record the finding. Security value is low (obscurity only). |
| RDS.25 | Custom admin username (not `postgres`) | **Met if** the `username` default is for example `dbadmin` and validation rejects `postgres`/`admin` |
| RDS.36 | RDS for PostgreSQL publishes logs to CloudWatch (`postgresql`) | **Not met** (not requested) |
| RDS.37 (Aurora PG) / RDS.7 / 12 / 14 / 15 / 16 / 24 / 27 / 34 / 35 | Aurora / cluster only | N/A |
| RDS.1 / RDS.31 / 38 | Public snapshot, DB security groups (EC2-Classic), and similar | N/A / met by default |

In-transit encryption: RDS for PostgreSQL 15+ default parameter groups set `rds.force_ssl = 1`. There is no dedicated FSBP control for PostgreSQL, but record it. A custom parameter group can pin it for older major versions.

### 7. Secrets Manager-managed master password behaviour

- `manage_master_user_password = true` makes RDS generate the password and store it in a Secrets Manager secret it owns (`rds!db-<id>`). The password never appears in Terraform config or state. `password` / `password_wo` must not be set; the provider rejects the combination.
- **Rotation**: enabled automatically by RDS with a **7-day** schedule by default. No Lambda is needed; RDS does the rotation. The schedule can be changed or disabled with `aws_secretsmanager_secret_rotation` against `master_user_secret[0].secret_arn` (provider doc example). This satisfies **SecretsManager.1** (rotation enabled) and **SecretsManager.4** (rotated within 90 days).
- **KMS**: `master_user_secret_kms_key_id` null means the account's `aws/secretsmanager` AWS managed key. A CMK ARN may be supplied (and should be an ARN for cross-account use). This is independent of the storage `kms_key_id`.
- **Lifecycle**: the secret is deleted with the DB instance. Tag changes and rotation go through RDS or the rotation resource. Do not create a separate `aws_secretsmanager_secret`.
- **Consumer implications**: apps must read the secret at connect time or cache it with a refresh, because it rotates weekly. `AmazonSSMManagedInstanceCore` does **not** grant `secretsmanager:GetSecretValue`. Consumers add a policy ARN through the managed-policy `for_each` list; if a CMK is used, that policy also needs `kms:Decrypt` on the secret key. Output `master_user_secret[0].secret_arn` so consumers can scope the policy.

### 8. CMK gotchas (optional CMK ARNs)

- **EBS CMK with Auto Scaling**: the key policy must allow the `AWSServiceRoleForAutoScaling` service-linked role to use the key (`kms:CreateGrant`, `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`). Without this, instances fail to launch and go straight to terminated ("Client.InvalidKMSKey.InvalidState"). Document this as a consumer precondition in the variable description.
- **RDS `kms_key_id`** forces replacement if changed after creation. Document it as effectively immutable.
- A null ARN means the AWS managed keys (`aws/ebs`, `aws/rds`, `aws/secretsmanager`). All encryption controls (EC2.3, RDS.3) still pass; only CMK-specific custom policies would flag this.

### 9. Security group tier chaining

AWS VPC docs recommend referencing security group IDs instead of CIDRs between tiers. Use standalone `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` (current provider best practice, one rule per resource, avoids the inline-rule conflicts and cycles of `aws_security_group_rule`):

| SG | Direction | Port | Peer |
| --- | --- | --- | --- |
| alb | ingress | 443, 80 | `0.0.0.0/0` (plus optional `::/0`). EC2.18 allows 80 and 443. |
| alb | egress | app port | `referenced_security_group_id = app` |
| app | ingress | app port | `referenced_security_group_id = alb` |
| app | egress | 443 | `0.0.0.0/0` (clarified: SSM, Secrets Manager, package repos) |
| app | egress | db port | `referenced_security_group_id = db` |
| db | ingress | db port | `referenced_security_group_id = app` |
| db | egress | none | (RDS needs no egress; the default allow-all is removed by the SG resource) |

Egress-to-anywhere on 443 triggers no FSBP control (EC2.18/19/53/54 evaluate ingress only). Private-subnet instances still need a NAT gateway or VPC endpoints (ssm, ssmmessages, ec2messages, secretsmanager) supplied by the consumer's VPC.

### 10. Controls this module will NOT satisfy (record in design.md)

| Control | Reason |
| --- | --- |
| ELB.4 | `drop_invalid_header_fields` not requested |
| ELB.5 | ALB access logs not requested |
| ELB.6 | ALB deletion protection not requested |
| ELB.16 | No WAF web ACL (NIST standard) |
| ELB.18 (possible) | HTTP :80 listener exists (redirect-only) |
| ELB.21 / ELB.22 | Health checks and traffic from ALB to targets use HTTP (TLS terminates at the ALB) |
| RDS.6 | Enhanced Monitoring not configured |
| RDS.9, RDS.36 | CloudWatch log exports (`postgresql`, `upgrade`) not requested |
| RDS.19–RDS.22 | No RDS event subscriptions |
| RDS.23 | Default port 5432 unless the design changes it |
| AutoScaling.6 | Single instance type (no mixed instances policy) |
| EC2.28 | No AWS Backup plan for EBS |
| Account/VPC scope (EC2.2, EC2.6, EC2.7, EC2.15) | Not managed by this module |

Conditionally met, depending on design defaults: RDS.10 (IAM auth on) and RDS.25 (non-`postgres` username). Recommend both be on by default.

### Rationale

- The provider docs confirm the insecure or legacy defaults that the module must override: `ssl_policy` defaults to `ELBSecurityPolicy-2016-08`, `storage_encrypted` false, `deletion_protection` false, `copy_tags_to_snapshot` false, `backup_retention_period` 0, `skip_final_snapshot` false (keep it, and supply `final_snapshot_identifier`), `performance_insights_enabled` false, and `monitoring_interval` 0. `auto_minor_version_upgrade` defaults to true and `publicly_accessible` to false; set both explicitly anyway.
- The provider docs confirm that `manage_master_user_password` conflicts with `password`/`password_wo`, that `master_user_secret_kms_key_id` falls back to the account default key, and that rotation is automatic every 7 days by default (use `aws_secretsmanager_secret_rotation` to override).
- Well-Architected Security (SEC05 network layers, SEC08 data at rest, SEC09 data in transit) and Reliability (REL10 multi-AZ fault isolation) map directly to SG chaining, encryption, TLS 1.2+, and multi-AZ ALB/ASG/RDS.

### Alternatives Considered

| Alternative | Why Not |
| --- | --- |
| `ELBSecurityPolicy-2016-08` (provider default) | Allows TLS 1.0/1.1; fails ELB.17 |
| `ELBSecurityPolicy-TLS13-1-3-2021-06` as default | Strictest, but breaks TLS 1.2-only clients; offer it as an allowed value |
| `password` / `random_password` for the master user | Plaintext in state, no managed rotation; fails the no-secrets-in-state goal |
| Inline `ingress`/`egress` blocks or `aws_security_group_rule` | Cyclic SG references and rule-conflict drift; the provider recommends the per-rule VPC SG rule resources |
| SSH key pair + port 22 | Fails EC2.13/53 intent; SSM Session Manager via `AmazonSSMManagedInstanceCore` replaces it |
| Launch configuration | Deprecated by AWS; fails AutoScaling.9 |
| Aurora PostgreSQL cluster | Different resource model (`aws_rds_cluster`) and cost; single-instance Multi-AZ meets the requirements |

### Sources

- AWS ELB: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html ; https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-listeners.html#redirect-actions
- Security Hub control references: https://docs.aws.amazon.com/securityhub/latest/userguide/elb-controls.html ; .../ec2-controls.html ; .../autoscaling-controls.html ; .../rds-controls.html ; .../secretsmanager-controls.html ; .../ssm-controls.html ; https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html
- RDS + Secrets Manager: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html
- RDS PostgreSQL SSL: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
- EC2 IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html
- EBS CMK with Auto Scaling key policy: https://docs.aws.amazon.com/autoscaling/ec2/userguide/key-policy-requirements-EBS-encryption.html
- Well-Architected Security and Reliability pillars: https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/ ; https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/
- Provider docs (hashicorp/aws): `aws_lb_listener`, `aws_db_instance` (manage_master_user_password, master_user_secret, rotation example), `aws_launch_template`, `aws_autoscaling_group`, `aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`

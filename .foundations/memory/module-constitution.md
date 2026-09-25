# Terraform Module Development Constitution

**Organization**: craigsloggett-lab
**Version**: 6.0.0
**Effective Date**: September 2026
**Purpose**: Non-negotiable principles for enterprise Terraform module development
**Authority**: This document governs what correct module code looks like. Workflow mechanics live in orchestrator skills. Agent behavior lives in AGENTS.md. If a rule exists here, it is not duplicated elsewhere.

---

## 1. Core Principles

### 1.1 Module-First Architecture

Modules MUST be authored using native Terraform resources from official providers following the [standard module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure).

- Modules MUST expose configurable inputs with secure defaults
- Consumers MUST get a secure, working baseline without overriding anything
- Conditional resource creation MUST be driven by the presence of an optional configuration object (`null` disables it); boolean `enable_*` flags only where the feature has nothing to configure
- Module versioning MUST follow semantic versioning, derived from conventional commit messages by the release workflow
- Research provider docs and AWS documentation before writing any resource code

### 1.2 Security-First by Default

Module code MUST assume zero trust. Security gaps in modules propagate to every consumer.

- Encryption, access controls, and logging MUST be enabled by default
- Security-sensitive inputs MUST default to the secure option (`public_access = false`, `encryption_enabled = true`)
- Modules MUST NOT require consumers to pass credentials
- Security controls MUST be toggleable via variables; defaults MUST always be the secure option
- Security rationale MUST be documented in code comments where non-obvious

### 1.3 Tests Before Code

Test files (`.tftest.hcl`) MUST be written before the module code they validate.

- Every module MUST have test files in `tests/`
- Tests MUST cover: secure defaults, full feature set, conditional creation disabled, input validation
- Security assertions (encryption, access controls, TLS enforcement) MUST exist before feature code
- Tests SHOULD use mocks where possible for fast iteration
- Integration tests SHOULD run in CI against a sandbox workspace

### 1.4 Single Design Document

All planning produces one file: `specs/{FEATURE}/design.md`.

- Variable names, resource inventories, and validation rules each appear exactly once
- No separate specification, plan, contract, data model, or task files
- The design document is the sole source of truth for the module

---

## 2. Code Standards

### 2.1 File Organization

Root modules MUST follow the standard HashiCorp module structure:

```
/
├── main.tf              # Data sources and calls to other modules
├── <service>.tf         # One file per AWS service: ec2.tf, iam.tf, kms.tf, s3.tf, vpc.tf, ...
├── locals.tf            # Derived values, each with a comment saying why it exists
├── check.tf             # check blocks: assertions that need data-source values
├── variables.tf         # Inputs, grouped under `# Required` then `# Optional`
├── outputs.tf           # Output value declarations
├── versions.tf          # Terraform and provider version constraints
├── README.md            # Auto-generated via terraform-docs
├── files/               # Scripts and unit files shipped to instances (shellcheck-clean)
├── templates/           # .tftpl files rendered with templatefile()
├── examples/<scenario>/ # One directory per scenario, each a complete root module
└── tests/               # .tftest.hcl files
```

Rules:

- Root module MUST NOT contain `provider {}` blocks — modules inherit providers from consumers
- `required_providers` and `required_version` MUST be declared in `versions.tf`
- Provider configuration (region, credentials) belongs ONLY in `examples/`
- Resources MUST be grouped by AWS service, one file per service; `main.tf` holds only data sources and module calls
- Examples are named by scenario (`examples/self-signed-tls/`), never `basic`/`complete`; at least one MUST exist
- Every example is self-contained: `providers.tf`, `versions.tf` pinning exact provider versions, its own `.terraform-docs.yml`, and `defaults.auto.tfvars.example`
- The README Usage section is the first example's `main.tf`, lifted by terraform-docs, so that file MUST read as consumer usage
- No monolithic configurations — resources MUST be logically grouped

### 2.2 Naming

- Resources: a descriptive noun for every resource, singletons included (`aws_s3_bucket.snapshots`, `aws_security_group.bastion`, `aws_lb.vault_enterprise`); `this` is never used
- Security group rules: one `aws_vpc_security_group_ingress_rule` or `aws_vpc_security_group_egress_rule` per rule, named `<subject>_<purpose>` (`vault_ssh`, `bastion_ntp`)
- Data sources: named for what they select (`aws_ami.selected`, `aws_vpc.existing`, `aws_ec2_instance_type.compute`)
- Variables: `snake_case`; one configuration object per subsystem (`vpc`, `compute`, `bastion`, `ami`, `kms_key`) rather than flat prefixed variables
- Outputs: `snake_case`, mirroring resource attribute names where possible
- Toggles: the presence of an optional object or field; `enable_<feature>` only when there is nothing to configure
- Names MUST NOT contain sensitive information (account IDs, secrets, PII)
- Names MUST be idempotent — no timestamps or random values unless functionally required
- Prefer `for_each` over `count` for stable resource addresses

### 2.3 Variables

Every variable MUST include:

- `description` — a sentence ending in a full stop; a `<<-EOT` heredoc when it runs past one line
- `type` — explicit constraint, never implicit `any`
- `sensitive = true` — for security-sensitive values

Structured inputs:

- One `object({...})` per subsystem; every field with a default uses `optional(type, default)` and the object itself defaults to `{}`
- A sub-object that is absent by default is `optional(object({...}), null)`; its presence is the toggle
- `nullable` is not used; nulls are handled through `optional()` defaults

Validation:

- Every constraint the module relies on MUST be a `validation` block, one condition per block
- `error_message` names the variable path and states the rule: `vpc.existing subnet ID lists must be non-empty when existing is set.`
- Cross-field rules on an object are validated on the object, not in `locals`

Ordering: required variables first under `# Required`, then `# Optional`; required variables MUST be the minimum needed for a working deployment

### 2.4 Outputs

- Outputs exposing secrets MUST be marked `sensitive = true`
- Conditional resources MUST use `try()` for graceful null handling:
  ```hcl
  output "vpc_id" {
    value = try(aws_vpc.created[0].id, null)
  }
  ```
- All outputs MUST have `description` for terraform-docs generation, a sentence ending in a full stop that says how to use the value where that is not obvious

### 2.5 Resource Patterns

- `count = <condition> ? 1 : 0` only as a 0/1 toggle; `for_each = toset(<list>)` for fan-out over input values; never `count` for multiples
- `lifecycle { create_before_destroy = true }` on security groups, launch templates, and anything a running instance references
- `check` blocks in `check.tf` for assertions that need data-source values (an EBS request against the instance type's baseline); variable `validation` for input shape
- `merge()` for tags — combine module defaults with consumer-provided tags
- `try()` for safely accessing optional nested values
- `dynamic` blocks only when the number of nested blocks is input-driven; otherwise write the blocks out
- `depends_on` only for dependencies that references cannot express
- MUST NOT hardcode values that consumers should control — expose as variables with defaults

### 2.6 Code Style

- Follow the [HashiCorp Style Guide](https://developer.hashicorp.com/terraform/language/style)
- A Title Case section comment above each logical group of resources (`# Bastion Host`, `# Vault Nodes`), followed by a blank line
- Block ordering: `count`/`for_each` first then a blank line, arguments, nested blocks, `tags`, `lifecycle`
- Auto-format with `terraform fmt`
- Comments explain why, never what; a comment stays only if removing it would cost the reader something the code cannot say
- All variables and outputs MUST have descriptions for terraform-docs

---

## 3. Security and Compliance

### 3.1 Secrets and Credentials

- Modules inherit providers from consumers — NEVER include `provider {}` blocks in root modules
- MUST NOT generate static credential variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or equivalent)
- Variables accepting secrets MUST be marked `sensitive = true`
- Outputs exposing secrets MUST be marked `sensitive = true`
- Provide integration points for secrets managers (accept ARNs for KMS keys, Secrets Manager) rather than managing secrets directly
- SHOULD use ephemeral resources for sensitive values where supported

### 3.2 AWS Security Baselines

These rules apply to all AWS modules. Non-AWS providers MUST add equivalent rules following this pattern.

| Control               | Requirement                                                                                                                                                    |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Encryption at rest    | Enabled by default. MUST NOT be disableable without an explicit variable.                                                                                      |
| Encryption in transit | Enforced via resource policy or platform default. Document which applies and cite evidence.                                                                    |
| Public access         | Blocked by default. S3: all four public access block flags `true`.                                                                                             |
| Security Groups       | Deny all by default. Allow only specific required ports and sources.                                                                                           |
| IAM roles             | Specific resource ARNs. No wildcards (`*`) unless unavoidable with documented justification.                                                                   |
| S3 force_destroy      | Configurable, default `false`. Examples MAY set `true` for testing.                                                                                            |
| RDS public access     | MUST NOT be publicly accessible unless explicitly justified.                                                                                                   |
| EC2 credentials       | IAM instance profiles. No embedded credentials.                                                                                                                |
| EC2 metadata          | `metadata_options` with `http_endpoint = "enabled"`, `http_tokens = "required"`, `http_put_response_hop_limit = 1` on every instance and launch template.      |
| AMI sourcing          | `data.aws_ami` MUST set `owners` and a `name` filter from variables. `most_recent` without `owners` is forbidden. Image IDs are never hard-coded in resources. |
| Lambda permissions    | Least-privilege execution roles with specific service permissions.                                                                                             |

### 3.3 Tagging

- Every resource sets `Name` from the `name` field of its configuration object (`tags = { Name = var.bastion.name }`); instances also set `volume_tags`
- All taggable resources MUST accept a `tags` variable (`map(string)`, default `{}`), merged beneath `Name` with `merge(var.tags, { Name = ... })`
- Required tag: `Name`. `ManagedBy` and organisation tags (`Environment`, `CostCenter`, `Owner`) come from the consumer's provider `default_tags`, not from the module

---

## 4. Version and Dependency Management

### 4.1 Provider Constraints

```hcl
terraform {
  required_version = "~> 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

- Modules MUST use pessimistic constraints: `~> 1.0` for Terraform, raised to the minor a feature needs (`~> 1.14`), and `~> MAJOR.0` for providers
- A provider major bump is a deliberate, tested change and a major release of the module; `>= 5.0, < 6.0` is the same constraint spelled long and is acceptable
- Examples and root modules pin exact provider versions (`6.64.0`); Dependabot moves them
- MUST NOT use `latest` or unconstrained versions

### 4.2 State Management

- Root modules MUST NOT include `backend {}` or `cloud {}` configuration blocks
- Examples MAY include backend configuration for testing
- State MUST NOT be committed to version control

### 4.3 Releases

- Semantic versioning: major (breaking interface changes), minor (new features/variables/outputs), patch (bug fixes/docs/security patches)
- Git tags MUST use `v` prefix: `v1.0.0`
- Releases are cut by the release workflow on merge to the default branch, with the version derived from conventional commit subjects: `feat` is minor, `fix` is patch, a `!` or `BREAKING CHANGE` footer is major
- Release requires: all tests pass, examples deploy and destroy cleanly, documentation current

---

## 5. Testing and Validation

### 5.1 Test Coverage

Every module MUST have `.tftest.hcl` files in three categories:

| Category | Provider | Command | Purpose |
|----------|----------|---------|---------|
| Unit tests | `mock_provider` | `plan` | Fast, deterministic validation of resource config, feature toggles, and input validation. No credentials needed. |
| Acceptance tests | Real | `plan` | Plan-level verification against real AWS APIs. Validates computed attributes and provider-resolved values. Requires credentials. |
| Integration tests | Real | `apply` | End-to-end resource creation and destruction. Verifies functional behavior in AWS. Requires credentials. |

Unit tests MUST cover: secure defaults, full features, feature interactions, validation errors, and validation boundaries.

### 5.2 Validation Pipeline

Every module MUST pass before release:

| Check | Tool | Blocks Release |
|-------|------|:-:|
| Formatting | `terraform fmt -check` | Yes |
| Syntax | `terraform validate` | Yes |
| Tests | `terraform test` | Yes |
| Linting | `tflint` | Yes |
| Security scan | `trivy config .` — no Critical or High | Yes |
| Documentation | `terraform-docs` — README current | Yes |

Pre-commit hooks MUST enforce these checks.

### 5.3 Test Organization

```
tests/
  unit_basic.tftest.hcl         # Unit: secure defaults with minimal inputs (mock providers)
  unit_complete.tftest.hcl      # Unit: all features enabled (mock providers)
  unit_edge_cases.tftest.hcl    # Unit: feature toggle combinations (mock providers)
  unit_validation.tftest.hcl    # Unit: invalid inputs (expect_failures) + boundary-pass (mock providers)
  acceptance.tftest.hcl         # Acceptance: plan with real providers (requires credentials)
  integration.tftest.hcl        # Integration: apply with real providers (requires credentials)
```

Each test file maps to a category and scenario group in `design.md` Section 5.

---

## 6. Change Management

### 6.1 Git Workflow

- Direct commits to `main` PROHIBITED
- All changes MUST be made via feature branches
- Pull requests with human review REQUIRED for all merges; squash merge only, so the PR title is the commit subject on the default branch
- PR titles and commit subjects are conventional commits with a capitalised subject and no trailing full stop: `feat: Add flow log retention`
- MUST NOT commit secrets, credentials, or sensitive data
- Test values for examples managed via `*.tfvars` files, not hardcoded in module code

### 6.2 Design Approval

Issue-driven workflow MUST pause between Design and Build+Test phases for human review of the design document.

- Gate signal: "approved" or "proceed" comment on the tracking issue
- Autonomous mode: MAY skip approval only if no CRITICAL security findings exist in the design

### 6.3 Quality Gates Between Phases

All four workflow phases are mandatory and sequential. Between phases:

| Gate | Condition |
|------|-----------|
| Understand -> Design | Requirements clear. No unresolved `[NEEDS CLARIFICATION]` markers. |
| Design -> Build+Test | Design document approved. No unresolved CRITICAL findings. |
| Build+Test -> Validate | `terraform validate` passes. All implementation checklist items complete. |
| Validate -> Complete | All validation checks from Section 5.2 pass. |

---

## 7. Operational Standards

### 7.1 Cost Optimization

- Modules SHOULD expose variables for instance sizing, storage, and scaling
- Defaults SHOULD be cost-effective — consumers override for production
- Cost-impacting configuration choices SHOULD be documented
- Examples SHOULD use minimal resource sizes

### 7.2 Observability

- Modules SHOULD enable monitoring by default where applicable
- Tags MUST include `Name` at minimum; `ManagedBy` comes from the consumer's `default_tags`
- Modules SHOULD output critical resource identifiers for monitoring integration
- Logging resources SHOULD be created by default with opt-out variables

### 7.3 HCP Terraform

- Organization, project, and workspace MUST be validated before any registry or workspace operations
- Sandbox workspaces for testing use pattern: `sandbox_<module>_<example>`
- Ephemeral workspaces MUST be deleted after testing
- Feature branch MUST be pushed to remote before creating workspaces

---

## 8. Governance

### 8.1 Constitution Maintenance

- Platform team maintains this constitution in version control
- Major changes require security and governance team review
- Module developers MAY propose amendments via pull request
- Constitution version MUST be referenced in agent prompts

### 8.2 Exception Process

Deviations from this constitution require:

1. Documented requirement driving the exception
2. Alternative approach with risk assessment
3. Platform team approval
4. Exception documented in code and centralized exceptions register
5. Review during next policy update cycle

### 8.3 Audit and Compliance

- All module code — AI-generated or human-authored — passes through the same policy enforcement
- Periodic audits verify constitution compliance
- Non-compliant patterns trigger constitution updates or module remediation
- Metrics track module quality, test coverage, and security posture

### 8.4 Documentation

- Every module MUST include `README.md` auto-generated via `terraform-docs`
- Complex logic MUST include inline comments explaining rationale
- Resource configurations MUST be justified in comments where non-obvious

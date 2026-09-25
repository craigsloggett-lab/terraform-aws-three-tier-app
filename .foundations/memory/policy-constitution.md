# Terraform Policy Development Constitution

**Organization**: [Your Organization Name]
**Version**: 1.0.0
**Effective Date**: May 2026
**Purpose**: Non-negotiable principles for enterprise Terraform policy development using **tfpolicy** (also written `tf-policy`). This is HashiCorp's HCL-based policy framework for HCP Terraform — it is **not** Sentinel. Do not refer to artifacts in this workflow as "Sentinel" or "Sentinel-style"; Sentinel is a separate product with its own non-HCL DSL, `.sentinel` files, and `import "tfplan/v2"` semantics. tfpolicy uses `.policy.hcl` / `.policytest.hcl`, `resource_policy`/`provider_policy`/`module_policy` blocks, and `core::*` functions as defined in this constitution.
**Authority**: This document governs what correct policy code looks like. Workflow mechanics live in orchestrator skills. Agent behavior lives in AGENTS.md. If a rule exists here, it is not duplicated elsewhere.

---

## 1. Policy Fundamentals

### 1.1 File Extensions

- Policy files MUST use the `.policy.hcl` extension
- Test files MUST use the `.policytest.hcl` extension
- No other extensions are valid for policy or policy test code

### 1.2 CLI Commands

- Validate policies: `tfpolicy validate --policies=<path>`
- Run tests: `tfpolicy test --policies=<path> [--tests=<path>]`
- Both commands MUST pass before any policy set is published

### 1.3 Policy Block Types

Three policy block types exist, each scoping enforcement to a different Terraform construct:

| Block Type        | Target                  | Example                                                                          |
| ----------------- | ----------------------- | -------------------------------------------------------------------------------- |
| `resource_policy` | Resource configurations | `resource_policy "aws_s3_bucket" "enforce_encryption" { ... }`                   |
| `provider_policy` | Provider configurations | `provider_policy "aws" "require_default_tags" { ... }`                           |
| `module_policy`   | Module calls            | `module_policy "registry.terraform.io/acme/*" "enforce_approved_source" { ... }` |

Rules:

- Every policy block takes exactly two labels: the target type and the policy name
- The first label identifies what the policy applies to (resource type, provider name, or module source pattern)
- The second label is a unique, descriptive policy name in `snake_case`
- Wildcard `*` is supported as the first label for universal policies that apply to all targets of that block type
- Prefer specific target types over wildcard `*` unless the policy is truly universal (e.g., tagging, naming conventions)

---

## 2. File Layout & Naming

### 2.1 Project Structure

Policy repositories MUST follow this structure:

```
/
├── policies/
│   ├── encryption.policy.hcl
│   ├── networking.policy.hcl
│   ├── iam.policy.hcl
│   ├── tagging.policy.hcl
│   ├── provider-governance.policy.hcl
│   └── module-governance.policy.hcl
├── tests/
│   ├── encryption.policytest.hcl
│   ├── networking.policytest.hcl
│   ├── iam.policytest.hcl
│   ├── tagging.policytest.hcl
│   ├── provider-governance.policytest.hcl
│   └── module-governance.policytest.hcl
├── plugins/
│   ├── src/
│   │   └── {name}/
│   │       └── main.go
│   └── bin/
│       └── {name}
└── README.md
```

### 2.2 Naming Conventions

- Policy files: `{domain}.policy.hcl` — group related policies by domain
- Test files: `{domain}.policytest.hcl` — one test file per policy file, matching names exactly
- Plugin source: `plugins/src/{name}/main.go`
- Plugin binary: `plugins/bin/{name}`
- Standard domains: `encryption`, `networking`, `iam`, `tagging`, `provider-governance`, `module-governance`
- Additional domains MAY be added for organization-specific concerns (e.g., `cost`, `compliance`, `data-residency`)

---

## 3. Policy Authoring Rules

### 3.1 Enforce Blocks

- Every `enforce` block MUST include both `condition` and `error_message`
- `error_message` MUST be actionable: state what is wrong AND how to fix it
- Bad: `"Encryption is not enabled."`
- Good: `"S3 bucket does not have server-side encryption enabled. Set 'server_side_encryption_configuration' with AES256 or aws:kms algorithm."`

### 3.2 Enforcement Level

- `enforcement_level` MUST be set explicitly on every policy — never rely on the default
- Encryption policies: `enforcement_level = "mandatory"`
- Public access policies: `enforcement_level = "mandatory"`
- Provider governance policies: `enforcement_level = "mandatory"`
- Module governance policies: `enforcement_level = "mandatory"`
- Tagging policies: MAY use `enforcement_level = "advisory"` for gradual rollout
- Security-critical policies MUST NOT omit `enforcement_level`

### 3.3 Targeting and Filtering

- Prefer specific resource types over wildcard `*` unless the policy is truly universal
- Use `filter` blocks to scope policies to subsets (e.g., by workspace tags, environment)
- Filter expressions MUST be deterministic — no side effects or external lookups

### 3.4 Logic and Computation

- Use `locals` blocks for intermediate computations, especially when processing `core::getresources()` results
- Functions use `core::` namespace for built-in functions
- Functions use `plugin::` namespace for custom plugin functions
- MUST NOT hardcode values that should be parameterized — use `input` blocks or `locals`
- Complex conditions MUST include inline comments explaining the logic
- Keep expressions single-line — the HCL parser has multi-line limitations during private beta

### 3.5 Null Safety

- ALWAYS use `core::try()` for optional attributes: `core::try(attrs.tags["Environment"], "")` not `attrs.tags["Environment"]`
- Check block existence with `core::length()` before indexing: verify `attrs.ingress != null && core::length(attrs.ingress) > 0` before `attrs.ingress[0]`
- Prefer `core::try()` over redundant length checks when it handles the empty case gracefully

### 3.6 Performance Rules

- `core::getresources(type, filter)` iterates ALL resources across ALL modules — O(N) complexity
- MUST cache `core::getresources()` results in top-level `locals` blocks, NEVER inside `resource_policy` blocks (would re-execute for every resource instance)
- `core::getdatasource()` makes REAL provider API calls (e.g., queries AWS APIs) — NOT cached state reads
- MUST NOT use `core::getdatasource()` inside `resource_policy` blocks (would call APIs for every resource)
- Use `core::getdatasource()` only in top-level `locals` when absolutely necessary
- Build lookup maps for O(1) access instead of iterating lists repeatedly
- Resources returned from `core::getresources()` have attributes at TOP LEVEL — access as `resource.bucket`, NOT `resource.attrs.bucket`

### 3.7 String Function Limitations

During the private beta, the following string operations are NOT available:

- No `core::startswith()` or `core::endswith()` — cannot check string prefixes/suffixes
- No substring matching — `core::contains()` only works for lists, NOT strings
- No regex functions — cannot validate string patterns
- Only available: `core::length()` for string length, `core::join()` to create strings from lists
- Workaround: Use explicit allowlists, exact matching, or simplified intent instead of string parsing

### 3.8 Collection Operations

- List comprehensions: `[for rule in attrs.ingress : rule if rule.to_port == 22]`
- `core::anytrue(list)` — returns true if any element is true
- `core::alltrue(list)` — returns true if all elements are true
- Quantifier expressions: `all v in collection : (condition)`, `any v in collection : (condition)`
- Convert sets to lists before indexing: `[for item in set : item][0]`

### 3.9 Block Argument Syntax

- Nested single blocks in `attrs` MUST use `=` sign assignment: `nested_block = { key = "value" }`
- Nested list/set blocks in `attrs` MUST use `= [{}]` syntax: `nested_blocks = [{ key = "value" }]`
- Top-level block arguments follow standard HCL block syntax

### 3.10 Cross-Resource Limitations

- New resources with cross-references may NOT have fully resolved values at policy evaluation time
- Cross-resource policies are more reliable for updates and explicit literal matches than for first-time resource creation
- Cannot distinguish between literal values, references, and computed values in attribute values
- Cannot navigate resource reference metadata — no equivalent of config attribute reference inspection exists in tfpolicy

---

## 4. Testing Rules

### 4.1 Coverage Requirements

- Every policy file MUST have a corresponding `.policytest.hcl` file
- Every policy MUST have at least one positive test case (expected to pass)
- Every policy MUST have at least one negative test case (`expect_failure = true`)
- Omitting either positive or negative tests is PROHIBITED

### 4.2 Test File Structure

- Test files MUST declare `policytest { targets = [...] }` explicitly — targets are never inferred
- Mock resources MUST include realistic attribute values that mirror actual Terraform plan output
- Provider policy tests MUST include `meta` blocks with `source` and `version`
- Module policy tests MUST include `meta` blocks with `source` and `version`
- Data source mocks use `data` blocks with static `attrs`

### 4.3 Cross-Resource Tests

- Use `skip = true` on helper resources that exist only to support cross-resource relationship tests
- Skipped resources are not evaluated by policies but are available for relationship lookups

### 4.4 Test Naming

- Test cases MUST have descriptive names reflecting the scenario: `"s3_bucket_with_encryption_enabled"`, `"s3_bucket_without_encryption_fails"`
- Negative test names SHOULD include `fails` or `denied` to signal intent

---

## 5. Security Defaults

### 5.1 Encryption Policies

- Default `enforcement_level = "mandatory"`
- MUST cover both at-rest and in-transit encryption where applicable
- MUST validate encryption key configuration (KMS key ARN, algorithm)

### 5.2 Public Access Policies

- Default `enforcement_level = "mandatory"`
- MUST block public exposure by default (S3 public access blocks, RDS public accessibility, security group 0.0.0.0/0 ingress)
- Exception paths MUST require explicit justification via tagging or workspace metadata

### 5.3 Provider and Module Governance

- Default `enforcement_level = "mandatory"`
- Provider policies MUST restrict to approved provider sources and version ranges
- Module policies MUST restrict to approved registry sources and version ranges
- Unapproved sources MUST be blocked, not merely warned

### 5.4 Tagging Policies

- MAY use `enforcement_level = "advisory"` during initial rollout
- MUST transition to `"mandatory"` once teams have had a documented grace period
- Required tags MUST be enumerated explicitly — no open-ended tag requirements

---

## 6. HCP Terraform Integration

### 6.1 Policy Set Deployment

- Policy sets MUST be VCS-backed — manual uploads are PROHIBITED for production policy sets
- Policy set repositories MUST pass `tfpolicy validate` and `tfpolicy test` in CI before merge

### 6.2 Evaluation Stages

| Stage               | Use Case                                                                         |
| ------------------- | -------------------------------------------------------------------------------- |
| Plan-time (default) | Configuration validation — resource arguments, provider settings, module sources |
| Apply-time          | Realized value validation — computed attributes, post-apply state                |

- Use plan-time evaluation unless the policy depends on computed values not available until apply
- MUST NOT use apply-time evaluation as a workaround for incomplete plan-time data when plan-time is sufficient

### 6.3 Workspace Targeting

- Scope policies to workspaces via workspace tags in `meta.tfe_workspace.tags`
- Use `filter` blocks referencing workspace tags for environment-specific enforcement (e.g., `"production"` vs `"development"`)
- Policies intended for all workspaces MUST NOT include workspace tag filters

---

## 7. Change Management

### 7.1 Git Workflow

- Direct commits to `main` PROHIBITED
- All changes MUST be made via feature branches
- Pull requests with human review REQUIRED for all merges
- MUST NOT commit secrets, credentials, or sensitive data in policy files or tests

### 7.2 Quality Gates

| Gate       | Condition                                                                    |
| ---------- | ---------------------------------------------------------------------------- |
| Pre-merge  | `tfpolicy validate --policies=policies/` passes                              |
| Pre-merge  | `tfpolicy test --policies=policies/ --tests=tests/` passes — all tests green |
| Pre-merge  | Peer review approved                                                         |
| Post-merge | Policy set syncs to HCP Terraform via VCS integration                        |

### 7.3 Versioning

- Policy repositories SHOULD use semantic versioning via Git tags
- Breaking changes (removing policies, tightening enforcement levels) MUST be communicated to affected teams before merge
- CHANGELOG entries MUST accompany every policy change

---

## 8. Governance

### 8.1 Constitution Maintenance

- Platform team maintains this constitution in version control
- Major changes require security and governance team review
- Policy developers MAY propose amendments via pull request
- Constitution version MUST be referenced in agent prompts

### 8.2 Exception Process

Deviations from this constitution require:

1. Documented requirement driving the exception
2. Alternative approach with risk assessment
3. Platform team approval
4. Exception documented in code and centralized exceptions register
5. Review during next policy update cycle

### 8.3 Audit and Compliance

- All policy code — AI-generated or human-authored — passes through the same review process
- Periodic audits verify constitution compliance
- Non-compliant patterns trigger constitution updates or policy remediation
- Metrics track policy coverage, test pass rates, and enforcement posture

# Policy Design: {policy-set-name}

**Branch**: feat/{name}
**Date**: {YYYY-MM-DD}
**Status**: Draft | Approved | Implementing | Complete
**Terraform**: >= {version}
**HCP Terraform Organization**: {organization}

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Policy Inventory & Architecture](#2-policy-inventory--architecture)
3. [Policy Specifications](#3-policy-specifications)
4. [Test Scenarios](#4-test-scenarios)
5. [HCP Terraform Configuration](#5-hcp-terraform-configuration)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

{One paragraph. What this policy set enforces, who it targets,
what organizational standard it implements. No implementation details.}

**Policy set type**: {e.g., "AWS security baseline", "provider governance", "module governance"}

**Target scope**: {Which workspaces, environments, or teams this policy set applies to.}

**Scope boundary**: {What is explicitly NOT covered -- prevents scope creep.}

### Requirements

**Functional requirements** -- what each policy must enforce (testable statements):

- {Testable statement of what a policy checks and what outcome it enforces}
- ...

**Non-functional requirements** -- compliance frameworks, enforcement strictness, evaluation constraints:

- {Compliance framework reference, override policy, or performance constraint}
- ...

{Requirements bridge Purpose and Architecture. They are testable and unambiguous.
Frame capabilities in terms of enforcement outcomes, not policy syntax.}

---

## 2. Policy Inventory & Architecture

### Architectural Decisions

{Each decision as a paragraph with this structure:}

**{Decision title}**: {What was chosen}.
_Rationale_: {Why, with MCP research citation if applicable}.
_Rejected_: {What was considered and why it was rejected}.

### Policy Inventory

| Policy File       | Policy Type                                     | Target                  | Policy Name   | Enforcement Level                          | Evaluation Stage       | Description        |
| ----------------- | ----------------------------------------------- | ----------------------- | ------------- | ------------------------------------------ | ---------------------- | ------------------ |
| {file.policy.hcl} | {resource_policy/provider_policy/module_policy} | {resource type or "\*"} | {policy_name} | {advisory/mandatory/mandatory-overridable} | {plan-time/apply-time} | {what it enforces} |

{This table is the SINGLE SOURCE OF TRUTH for the policy set's policy files.
Each row maps to exactly one policy block in one .policy.hcl file.
A single file may contain multiple policy blocks -- list each block as a separate row.}

### Input Variables

| Input Name | Type                          | Default       | Description   |
| ---------- | ----------------------------- | ------------- | ------------- |
| {name}     | {string/number/bool/list/map} | {value or --} | {description} |

{Input variables are defined in `input` blocks within .policy.hcl files.
Only include this table if the policy set uses `input` blocks. Omit if none.}

### Plugin Inventory

| Plugin Name | Source        | Functions Provided     | Description        |
| ----------- | ------------- | ---------------------- | ------------------ |
| {name}      | {source path} | {function1, function2} | {what it provides} |

{Plugins extend policy evaluation with custom functions.
Only include this table if the policy set uses plugins. Omit if none.}

### Compliance Rule Mapping

| Policy Name   | Rule ID   | Framework       | Rule Description                    |
| ------------- | --------- | --------------- | ----------------------------------- |
| {policy_name} | {rule-id} | {CIS/WA/custom} | {what the compliance rule requires} |

{If consuming tf-research-policy-aws YAML output, reference the YAML rule IDs here.
Only include this table if policies map to external compliance rules. Omit if none.}

---

## 3. Policy Specifications

{For each policy listed in the Policy Inventory (Section 2), provide a full specification.
Order must match the inventory table.}

### Policy: {policy_name}

**File**: {file.policy.hcl}
**Enforcement**: {advisory/mandatory/mandatory-overridable}
**Stage**: {plan-time/apply-time}

**Filter logic**:

```hcl
{filter block if applicable, or "No filter -- evaluates all targeted resources."}
```

**Locals / computed values**:

```hcl
{locals block if applicable, or "No locals."}
```

**Policy block**:

```hcl
resource_policy "{target_type}" "{policy_name}" {
  enforcement_level = "{enforcement_level}"

  enforce {
    condition = {HCL condition expression}
    error_message = "{Actionable error message telling the operator exactly what to fix}"
  }
}
```

**Null safety**: {List any core::try() wrappers needed for optional attributes.}

**Performance notes**: {If using getresources/getdatasource, note caching strategy.
getresources() results MUST be cached in top-level locals, never inside resource_policy.
getdatasource() calls real provider APIs — avoid inside resource_policy blocks.}

**Cross-resource relationships**: {If using getresources/getdatasource to correlate across
resource types, describe the relationship and attribute access pattern.
Resources from getresources() use top-level attribute access: resource.bucket, NOT resource.attrs.bucket.
Otherwise "None."}

{Rules:

- Error messages must be actionable -- tell the operator what to change, not just what failed.
- Each enforce block maps 1:1 to a row in the Policy Inventory.
- If a policy has multiple enforce conditions, list each condition separately.
- Use getresources/getdatasource for cross-resource checks; document the lookup pattern.
- Always wrap optional attributes with core::try() for null safety.
- Keep expressions single-line (HCL parser beta limitation).
- Cache getresources() in top-level locals for O(1) reuse -- never call inside resource_policy.
- Resources from getresources() use direct attribute access (resource.bucket, not resource.attrs.bucket).
- No startswith/endswith/regex available -- use exact match or allowlists.
- Convert sets to lists before indexing: [for item in set : item][0].}

---

## 4. Test Scenarios

### Test Strategy

- **Test framework**: HCP Terraform policy tests using `.policytest.hcl` files
- **Mock approach**: Each test case defines a `resource`, `provider`, `module`, or `data` block with `attrs` (and optionally `meta`) that simulate compliant or non-compliant infrastructure
- **Targeted policies**: {list policy files under test}
- **Helper resources**: Use `skip = true` on mock resources that exist only to satisfy cross-resource relationship lookups

### Policy: {policy_name}

#### Test Case: Compliant resource (pass)

**Purpose**: Verify the policy passes when the resource meets all requirements
**Policy Target**: {resource type}

**Mock Resource**:

```hcl
resource "{resource_type}" "{test_case_name}" {
  attrs = {
    {attribute} = {compliant_value}
  }
}
```

**Expected Result**: Pass

#### Test Case: Non-compliant resource (fail)

**Purpose**: Verify the policy fails when the resource violates the requirement
**Policy Target**: {resource type}

**Mock Resource**:

```hcl
resource "{resource_type}" "{test_case_name}_fails" {
  expect_failure = true
  attrs = {
    {attribute} = {non_compliant_value}
  }
}
```

**Expected Result**: Fail (`expect_failure = true`)
**Expected Error**: "{substring of the actionable error message}"

#### Test Case: {Edge case name}

**Purpose**: {What edge case this covers -- filter bypass, wildcard, cross-resource, missing attribute}
**Policy Target**: {resource type}

**Mock Resource**:

```hcl
resource "{resource_type}" "{test_case_name}" {
  attrs = {
    {attribute} = {edge_case_value}
  }
}
```

**Helper Resources** (if cross-resource):

```hcl
resource "{related_resource_type}" "{helper_name}" {
  skip = true
  attrs = {
    {attribute} = {value}
  }
}
```

**Expected Result**: {Pass/Fail}

{Rules:

- Every policy in the inventory must have at least one pass and one fail test case.
- Each test case maps 1:1 to a run block in a .policytest.hcl file.
- Edge cases should cover: filter bypass, wildcard behavior, missing attributes,
  cross-resource scenarios, and boundary values for numeric thresholds.
- Use skip = true for helper resources that exist only to satisfy relationship lookups.}

---

## 5. HCP Terraform Configuration

### Policy Set Organization

| Policy Set Name   | Policy Files                         | Description              |
| ----------------- | ------------------------------------ | ------------------------ |
| {policy-set-name} | {file1.policy.hcl, file2.policy.hcl} | {what this set enforces} |

{A policy set groups related policies for deployment to HCP Terraform.
One design may define one or more policy sets if logical separation is needed.}

### Workspace Targeting

| Policy Set Name   | Targeting Strategy                | Selector                         | Description          |
| ----------------- | --------------------------------- | -------------------------------- | -------------------- |
| {policy-set-name} | {tag-based/workspace-list/global} | {tag pattern or workspace names} | {why this targeting} |

{Rules:

- Prefer tag-based targeting for scalability.
- Document which workspace tags must exist for the policies to apply.
- If using workspace-list targeting, document the maintenance burden.}

### Evaluation Stage Decisions

| Policy Name   | Stage                  | Rationale                                                                             |
| ------------- | ---------------------- | ------------------------------------------------------------------------------------- |
| {policy_name} | {plan-time/apply-time} | {why this stage -- e.g., "needs planned resource values" or "needs apply-time state"} |

### Override Permissions

| Enforcement Level     | Who Can Override | Approval Process                                    |
| --------------------- | ---------------- | --------------------------------------------------- |
| mandatory-overridable | {team or role}   | {process -- e.g., "requires comment justification"} |

{Only include this table if the policy set uses mandatory-overridable enforcement.
Omit if all policies are advisory or mandatory.}

---

## 6. Implementation Checklist

- [ ] **A: Scaffold** -- Create `policies/` directory, base `.policy.hcl` files with top-level `input` / `locals` / empty policy block stubs
- [ ] **B: Core policies** -- Implement single-resource policy logic and `enforce` conditions
- [ ] **C: Cross-resource policies** -- Implement policies that use `core::getresources()` / `core::getdatasource()` for relationship checks
- [ ] **D: Plugins** -- Implement custom plugin functions (if any)
- [ ] **E: HCP configuration** -- Configure policy sets, workspace targeting, and enforcement levels (`README.md` + HCP-side config)
- [ ] **F: Validation** -- Final `tfpolicy validate` + `tfpolicy test` pass

{Keep this to 4-8 items. Each item = one implementation pass.
NOT a 34-task breakdown. Each item should be completable in one agent turn.
Each item must have clear scope boundaries -- list which files it creates/modifies.
Items must not overlap: if A creates a file, B must not also create that file.
Omit items that do not apply (e.g., skip Plugins if no plugins are used).}

---

## 7. Open Questions

{Any deferred decisions marked [DEFERRED] with context.
Empty section if all questions resolved during clarification.}

---

## Template Rules

1. No section may reference another section by line number
2. Policy names appear exactly once -- in Policy Inventory (Section 2)
3. Each policy specification (Section 3) maps 1:1 to a row in Policy Inventory (Section 2)
4. Each test case maps 1:1 to a run block in a .policytest.hcl file
5. Implementation checklist items are coarse-grained -- one per logical unit with explicit file scope
6. Error messages in policy specifications must be actionable -- tell the operator what to fix
7. Input variable names appear exactly once -- in the Input Variables table (Section 2)

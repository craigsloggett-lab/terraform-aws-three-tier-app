#!/usr/bin/env bash
# post-issue-progress.sh — Standardised issue progress commenting
#
# Usage:
#   post-issue-progress.sh <issue_number> <phase_name> <status> [summary] [details]
#
# Arguments:
#   issue_number  GitHub issue number (required)
#   phase_name    Human-readable phase name, e.g. "Environment Validation" (required)
#   status        One of: started, in-progress, complete, failed (required)
#   summary       Brief one-line summary of outcome (optional for started/in-progress, recommended for complete/failed)
#   details       Multi-line details/bullets to append as **Summary** block (optional)
#
# On "complete", if <phase_name> matches a "- [ ] Phase N: <name>" entry in the
# issue body's Status checklist (canonical phase names: Clarify, Design,
# Implement, Validate), the checkbox is ticked automatically. Matching is
# case-insensitive and an optional "Phase N: " prefix on <phase_name> is
# accepted. Non-matching phase names (e.g. sub-steps like "Environment
# Validation") leave the checklist untouched.
#
# Examples:
#   post-issue-progress.sh 42 "Environment Validation" "complete" "All gates passed"
#   post-issue-progress.sh 42 "Specify" "complete" "design.md generated (12 sections)" "- Defined VPC with 3 AZs
# - 4 success criteria with measurable thresholds"
#   post-issue-progress.sh 42 "Sandbox Testing" "failed" "terraform apply failed: missing provider"
#   post-issue-progress.sh 42 "Implementation Phase 1" "started"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

if [[ $# -lt 3 ]]; then
  echo "Usage: post-issue-progress.sh <issue_number> <phase_name> <status> [summary]" >&2
  echo "  status: started | in-progress | complete | failed" >&2
  exit 1
fi

ISSUE_NUMBER="$1"
PHASE_NAME="$2"
STATUS="$3"
SUMMARY="${4:-}"
DETAILS="${5:-}"

# Validate status
case "$STATUS" in
  started|in-progress|complete|failed) ;;
  *)
    echo "Error: status must be one of: started, in-progress, complete, failed (got: $STATUS)" >&2
    exit 1
    ;;
esac

# Build comment body
case "$STATUS" in
  started|in-progress)
    ICON="🔄"
    STATUS_LABEL="In Progress"
    BODY="## ${ICON} Phase: ${PHASE_NAME}
**Status**: ${STATUS_LABEL}"
    if [[ -n "$SUMMARY" ]]; then
      BODY="${BODY}
${SUMMARY}"
    fi
    ;;
  complete)
    ICON="✅"
    STATUS_LABEL="Complete"
    BODY="## ${ICON} Phase: ${PHASE_NAME}
**Status**: ${STATUS_LABEL}"
    if [[ -n "$SUMMARY" ]]; then
      BODY="${BODY}
**Result**: ${SUMMARY}"
    fi
    ;;
  failed)
    ICON="❌"
    STATUS_LABEL="Failed"
    BODY="## ${ICON} Phase: ${PHASE_NAME}
**Status**: ${STATUS_LABEL}"
    if [[ -n "$SUMMARY" ]]; then
      BODY="${BODY}
**Error**: ${SUMMARY}"
    fi
    ;;
esac

# Append details block if provided
if [[ -n "$DETAILS" ]]; then
  BODY="${BODY}

**Summary**:
${DETAILS}"
fi

# Post to GitHub issue (non-interactive: prevent gh from hanging on prompts)
ensure_gh_noninteractive
gh issue comment "$ISSUE_NUMBER" --body "$BODY" < /dev/null

# On phase completion, tick the matching "- [ ] Phase N: <name>" checkbox in
# the issue body's Status checklist. No-op when nothing matches.
if [[ "$STATUS" == "complete" ]]; then
  PHASE_LABEL="$(printf '%s' "$PHASE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/^phase [0-9]+: *//')"
  ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --json body --jq .body < /dev/null 2>/dev/null || true)"
  if [[ -n "$ISSUE_BODY" ]]; then
    UPDATED_BODY="$(printf '%s\n' "$ISSUE_BODY" | awk -v phase="$PHASE_LABEL" '
      {
        line = $0
        lower = tolower(line)
        gsub(/\r/, "", lower)
        sub(/[[:space:]]+$/, "", lower)
        if (lower ~ /^- \[ \] phase [0-9]+: /) {
          label = lower
          sub(/^- \[ \] phase [0-9]+: /, "", label)
          if (label == phase) sub(/\[ \]/, "[x]", line)
        }
        print line
      }')"
    if [[ "$UPDATED_BODY" != "$ISSUE_BODY" ]]; then
      BODY_FILE="$(mktemp)"
      printf '%s\n' "$UPDATED_BODY" > "$BODY_FILE"
      gh issue edit "$ISSUE_NUMBER" --body-file "$BODY_FILE" < /dev/null || true
      rm -f "$BODY_FILE"
    fi
  fi
fi

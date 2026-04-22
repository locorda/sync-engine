#!/usr/bin/env bash
# Creates all standard labels for the locorda/sync-engine GitHub repository.
# Requires the GitHub CLI (gh) to be installed and authenticated.
#
# Usage:
#   ./tool/setup_github_labels.sh
#
# Run once after repository creation, or re-run to update existing labels.

set -euo pipefail

REPO="locorda/sync-engine"

create_label() {
  local name="$1"
  local color="$2"
  local description="$3"

  if gh label create "$name" --color "$color" --description "$description" --repo "$REPO" 2>/dev/null; then
    echo "  created: $name"
  else
    # Label already exists — update it
    gh label edit "$name" --color "$color" --description "$description" --repo "$REPO" 2>/dev/null \
      && echo "  updated: $name" \
      || echo "  skipped: $name (no change needed)"
  fi
}

echo "=== Type labels (no duplicates of GitHub defaults: bug, enhancement, documentation, duplicate, invalid, question, wontfix) ==="
create_label "type: performance"  "e4e669" "Performance improvement"
create_label "type: refactor"     "cfd3d7" "Code cleanup without behaviour change"
create_label "type: test"         "bfd4f2" "Tests only"
create_label "type: ci"           "f9d0c4" "CI/CD pipeline changes"

echo ""
echo "=== Priority labels ==="
create_label "priority: critical" "b60205" "Blocking — must fix immediately"
create_label "priority: high"     "e11d48" "Important — fix soon"
create_label "priority: medium"   "f97316" "Normal priority"
create_label "priority: low"      "fef9c3" "Nice to have"

echo ""
echo "=== Status labels ==="
create_label "status: needs triage"       "ededed" "Not yet assessed"
create_label "status: needs discussion"   "d4c5f9" "Requires design discussion before implementing"
create_label "status: in progress"        "0e8a16" "Actively being worked on"
create_label "status: blocked"            "b60205" "Waiting on something external"

echo ""
echo "=== Package labels ==="
create_label "pkg: locorda"                        "1d76db" "Main entry point package"
create_label "pkg: locorda_core"                   "1d76db" "Platform-agnostic sync engine"
create_label "pkg: locorda_annotations"            "1d76db" "CRDT merge strategy annotations"
create_label "pkg: locorda_builder"                "1d76db" "Code generation (build_runner)"
create_label "pkg: locorda_dev"                    "1d76db" "Developer tooling"
create_label "pkg: locorda_dir"                    "1d76db" "Local directory storage backend"
create_label "pkg: locorda_drift"                  "1d76db" "Drift (SQLite) storage backend"
create_label "pkg: locorda_flutter"                "1d76db" "Flutter integration"
create_label "pkg: locorda_flutter_core"           "1d76db" "Flutter core utilities"
create_label "pkg: locorda_gdrive"                 "1d76db" "Google Drive backend"
create_label "pkg: locorda_init_generator"         "1d76db" "Init code generator"
create_label "pkg: locorda_mapping_bootstrap_generator" "1d76db" "Mapping bootstrap generator"
create_label "pkg: locorda_objects"                "1d76db" "Shared domain objects"
create_label "pkg: locorda_solid"                  "1d76db" "Solid Pod integration"
create_label "pkg: locorda_solid_auth"             "1d76db" "Solid authentication"
create_label "pkg: locorda_solid_auth_worker"      "1d76db" "Solid auth worker isolate"
create_label "pkg: locorda_solid_core"             "1d76db" "Solid core utilities"
create_label "pkg: locorda_solid_ui"               "1d76db" "Solid Flutter UI components"
create_label "pkg: locorda_ui"                     "1d76db" "Generic Flutter UI components"
create_label "pkg: locorda_worker"                 "1d76db" "Worker isolate infrastructure"

echo ""
echo "Done. All labels are in sync with $REPO."

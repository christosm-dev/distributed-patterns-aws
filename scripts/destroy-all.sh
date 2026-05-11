#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { echo ""; echo "▶ $*"; }

for project in "$REPO_ROOT"/terraform/projects/*/; do
  name="$(basename "$project")"
  log "destroying $name"
  terraform -chdir="$project" destroy -auto-approve -no-color -input=false 2>/dev/null || true
  rm -f "$project/terraform.tfstate" "$project/terraform.tfstate.backup"
  echo "  ✓ $name destroyed and state removed"
done

echo ""
echo "✓ all projects destroyed"

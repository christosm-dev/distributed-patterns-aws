#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ────────────────────────────────────────────────────────────────

log()  { echo ""; echo "▶ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

wait_for_http() {
  local url="$1" timeout="${2:-60}" interval=3 elapsed=0
  echo "  waiting for $url ..."
  while ! curl -sf "$url" > /dev/null 2>&1; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    [ "$elapsed" -ge "$timeout" ] && fail "timed out waiting for $url after ${timeout}s"
  done
  echo "  $url is ready"
}

apply_project() {
  local project="$1"
  log "terraform apply — $project"
  terraform -chdir="$REPO_ROOT/terraform/projects/$project" init -upgrade -no-color -input=false > /dev/null 2>&1
  terraform -chdir="$REPO_ROOT/terraform/projects/$project" apply -auto-approve -no-color -input=false > /dev/null 2>&1
}

test_project() {
  local project="$1"
  log "pytest — $project"
  pytest "$REPO_ROOT/terraform/projects/$project/tests" -v
}

# ── Projects ───────────────────────────────────────────────────────────────

# Project 01 — Sidecar
apply_project "01-sidecar"
wait_for_http "http://localhost:5000/health"
test_project  "01-sidecar"

# Project 02 — Ambassador
apply_project "02-ambassador"
test_project  "02-ambassador"

# Project 03 — Load-Balanced
apply_project "03-load-balanced"
wait_for_http "http://localhost:8080/health"
test_project  "03-load-balanced"

# Project 04 — Scatter/Gather
apply_project "04-scatter-gather"
test_project  "04-scatter-gather"

# Project 05 — Event Pipeline
apply_project "05-event-pipeline"
test_project  "05-event-pipeline"

# Project 06 — Work Queue
apply_project "06-work-queue"
test_project  "06-work-queue"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "✓ all projects applied and tested successfully"

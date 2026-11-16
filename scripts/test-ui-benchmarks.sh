#!/bin/bash
# Optimized, measured native UI. No production data or live system operations.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
edition=()
if [ "${1:-}" = --appstore ]; then edition=(--appstore); shift; fi
[ "$#" = 0 ] || { echo 'Usage: scripts/test-ui-benchmarks.sh [--appstore]' >&2; exit 2; }
python3 -I scripts/check-ui-coverage.py sources
work=$(mktemp -d /private/tmp/mymole-ui-kpi-XXXXXXXX)
lease=$(python3 -I scripts/test-cleanup.py lease "$work")
trap 'result=$?; trap - EXIT; python3 -I scripts/test-cleanup.py clean "$work" "$lease" || result=1; exit "$result"' EXIT
: > "$work/combined"
# Every scenario runs, so one run shows every failure; the build stops at
# the first, since nothing after it could run.
failed=()
while IFS= read -r scenario; do
  echo "Running UI KPI: $scenario"
  if ! MYMOLE_UI_BENCHMARK=1 MYMOLE_STRICT_UI_BENCHMARKS=1 MYMOLE_UI_BENCHMARK_SCOPE="${MYMOLE_UI_BENCHMARK_SCOPE:-full}" \
    scripts/test-guarded.sh --release ${edition[@]+"${edition[@]}"} --filter "$scenario" > "$work/scenario" 2>&1; then
    grep -E 'swift:[0-9]+:[0-9]+: error:|recorded an issue|Expectation failed|^↳ |Fatal error|Assertion|Precondition|Trace/BPT|ui-bench |Cannot verify|failed \(exit' "$work/scenario" >&2 || true
    echo "UI KPI scenario failed: $scenario" >&2
    if grep -qE 'swift:[0-9]+:[0-9]+: error:' "$work/scenario"; then exit 1; fi
    failed+=("$scenario")
    continue
  fi
  cat "$work/scenario" >> "$work/combined"
  grep -E '^ui-bench ' "$work/scenario"
done < <(python3 -I scripts/check-ui-coverage.py benchmark-tests)
if [ ${#failed[@]} -gt 0 ]; then
  echo "UI KPI scenarios failed: ${failed[*]}" >&2
  exit 1
fi
python3 -I scripts/check-ui-coverage.py benchmarks "$work/combined"

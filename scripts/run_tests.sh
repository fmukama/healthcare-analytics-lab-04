#!/usr/bin/env bash
# =============================================================================
# Runs every tests/NN_*.sql and fails loudly if any assertion fails.
#
# The helpers in tests/00_helpers.sql RAISE EXCEPTION on a failed assertion.
# With ON_ERROR_STOP=1 that aborts psql with a non-zero exit, which this script
# collects and re-raises so `make test` (and CI) go red.
#
# A fast query that returns a different number than the source is a bug shipped
# to the business. This script is what makes the rewrites trustworthy.
# =============================================================================
set -uo pipefail        # deliberately NOT -e: a failing test must be recorded
                        # and reported, not abort the run before later tests
                        # get a chance to execute.

PSQL="psql -U ${PGUSER:-lab} -d ${PGDATABASE:-healthcare} -v ON_ERROR_STOP=1"
OUT=/work/out/test_results.txt
mkdir -p /work/out

shopt -s nullglob       # an empty tests/ dir must yield zero files, not the
                        # literal unexpanded glob string.

run_all() {
  echo "=============================================================="
  echo " TEST RUN"
  echo "=============================================================="

  local fail=0 total=0 files=(/work/tests/[0-9][0-9]_*.sql)

  if [ ${#files[@]} -eq 0 ]; then
    echo ""
    echo "!! no test files found in /work/tests/"
    echo ""
    echo "RESULT: NO TESTS"
    return 1
  fi

  for f in "${files[@]}"; do
    case "$f" in *00_helpers.sql) continue ;; esac   # helpers are loaded by
                                                     # `make test`, not asserted
    total=$((total + 1))
    echo ""
    echo "### $(basename "$f")"
    # RAISE NOTICE writes to stderr; fold it into stdout so PASS lines show up
    # in the captured report alongside failures.
    if $PSQL -f "$f" 2>&1; then
      :
    else
      echo "    ^^ FAILED: $(basename "$f")"
      fail=$((fail + 1))
    fi
  done

  echo ""
  echo "--------------------------------------------------------------"
  if [ "$fail" -eq 0 ]; then
    echo "RESULT: ALL TESTS PASSED   ($total files)"
    return 0
  fi
  echo "RESULT: FAILURES           ($fail of $total files failed)"
  return 1
}

# tee so the report is both visible now and kept for the deliverables. The
# exit status must come from run_all, not from tee, hence PIPESTATUS.
run_all | tee "$OUT"
exit "${PIPESTATUS[0]}"

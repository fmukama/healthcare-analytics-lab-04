#!/usr/bin/env bash
# usage: run_query.sh <phase: oltp|star> <label: q1..q4|sq1..sq4> <sql_dir> [runs]
# Resolves <sql_dir>/<label>_*.sql, so file naming stays flexible.
set -euo pipefail

PHASE="$1"; LABEL="$2"; SQLDIR="$3"; RUNS="${4:-3}"
PSQL="psql -U ${PGUSER:-lab} -d ${PGDATABASE:-healthcare} -v ON_ERROR_STOP=1"
OUT="/work/out/${LABEL}.txt"
LOG="/work/logs/${PHASE}_${LABEL}.log"
mkdir -p /work/out /work/logs

SQL=$(ls "$SQLDIR"/"${LABEL}"_*.sql 2>/dev/null | head -1)
if [ -z "$SQL" ]; then
  echo "!! no file matching ${SQLDIR}/${LABEL}_*.sql — have you written it yet?" >&2
  exit 1
fi

# Wrap the (single-statement) query file in EXPLAIN ANALYZE.
EXP=$(mktemp)
{ echo "EXPLAIN (ANALYZE, BUFFERS)"; cat "$SQL"; } > "$EXP"

emit() { echo "$@" | tee -a "$OUT"; }          # -> terminal AND file

: > "$OUT"
emit "=============================================================="
emit " $(echo "$PHASE" | tr a-z A-Z)  ::  $LABEL"
emit " source: $SQL"
emit "=============================================================="
emit ""
emit "--- SQL ------------------------------------------------------"
cat "$SQL" | tee -a "$OUT"
emit ""
emit "--- RESULTS (first 25 rows) ----------------------------------"
# `|| true` is required: head -30 exits as soon as it has its 30 lines, which
# SIGPIPEs psql on any result set bigger than that (the norm at real volume).
# Under `set -o pipefail` that SIGPIPE (exit 141) would otherwise kill this
# script before the timing runs / EXPLAIN below ever execute. Real query
# failures are still caught below at the unpiped warm-up run (line ~39).
$PSQL -P pager=off -c "\\set FETCH_COUNT 0" -f "$SQL" 2>&1 | head -30 | tee -a "$OUT" || true
emit ""

# Warm the cache: the FIRST run of anything is dominated by disk I/O and is not
# what you want to report. Discard it, then measure.
$PSQL -f "$SQL" > /dev/null 2>&1

emit "--- TIMINGS: $RUNS runs, warm cache -------------------------"
times=()
for i in $(seq 1 "$RUNS"); do
  ms=$($PSQL -At -f "$EXP" | grep -i 'Execution Time' | grep -oE '[0-9.]+' | head -1)
  emit "  run $i : ${ms} ms"
  times+=("$ms")
done
median=$(printf '%s\n' "${times[@]}" | sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
emit "  MEDIAN : ${median} ms"
emit ""

emit "--- QUERY PLAN -----------------------------------------------"
$PSQL -At -f "$EXP" | tee -a "$OUT"
emit ""

# machine-readable record for bench.sh
echo "${PHASE},${LABEL},${median}" >> /work/out/timings.csv
cp "$OUT" "$LOG"
echo ">> ${PHASE}/${LABEL}: median ${median} ms  ->  ${OUT}"
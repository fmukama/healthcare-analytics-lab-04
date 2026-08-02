#!/usr/bin/env bash
# =============================================================================
# Turns out/timings.csv into the OLTP-vs-star comparison table.
#
# Contract with run_query.sh: one line per run, "phase,label,median_ms".
# OLTP runs land as `oltp,q1,...`, star runs as `star,sq1,...`. Rename a label
# in one place and you must rename it in the other.
# =============================================================================
set -euo pipefail

CSV=/work/out/timings.csv
OUT=/work/out/bench.txt
mkdir -p /work/out

if [ ! -f "$CSV" ]; then
  echo "!! $CSV not found - run some queries first (make q1 .. make sq4)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# timings.csv is APPENDED to, never truncated, so re-running a query leaves an
# older row behind. Taking the last match per label is correct, but a CSV that
# quietly mixes runs from different dataset sizes will produce a speedup table
# that looks fine and means nothing. Warn when that has happened - a silent
# wrong number is far worse than a noisy right one.
# ---------------------------------------------------------------------------
dupes=$(awk -F, 'NF>=3 {seen[$1","$2]++} END {for (k in seen) if (seen[k]>1) printf "%s x%d\n", k, seen[k]}' "$CSV")

{
  echo "=============================================================="
  echo " PERFORMANCE COMPARISON  (median of 3 warm runs, same instance)"
  echo "=============================================================="

  if [ -n "$dupes" ]; then
    echo ""
    echo " WARNING: timings.csv holds more than one run for:"
    echo "$dupes" | sed 's/^/          /'
    echo "          The most recent run of each is used below. If those runs"
    echo "          came from different dataset sizes, these ratios are"
    echo "          meaningless - run 'make clean' and re-measure."
  fi

  echo ""
  printf "%-6s %14s %14s %11s\n" "QUERY" "OLTP (ms)" "STAR (ms)" "SPEEDUP"
  echo "--------------------------------------------------------------"

  # `print v` and NOT `print v+0`: the +0 coerces to a number, and awk's default
  # OFMT of %.6g then silently truncates anything past 6 significant digits --
  # 10375.592 ms would print as 10375.6. Keeping the field as the string it was
  # read as preserves the measurement exactly. Empty defaults to 0 so the
  # numeric guards below stay syntactically valid.
  for n in 1 2 3 4; do
    o=$(awk -F, -v q="q$n"  '$1=="oltp" && $2==q {v=$3} END{print (v=="" ? 0 : v)}' "$CSV")
    s=$(awk -F, -v q="sq$n" '$1=="star" && $2==q {v=$3} END{print (v=="" ? 0 : v)}' "$CSV")

    if awk "BEGIN{exit !($o>0 && $s>0)}"; then
      printf "%-6s %14s %14s %10.1fx\n" "Q$n" "$o" "$s" "$(awk "BEGIN{print $o/$s}")"
    elif awk "BEGIN{exit !($o>0)}"; then
      printf "%-6s %14s %14s %11s\n" "Q$n" "$o" "-" "not run"
    else
      printf "%-6s %14s %14s %11s\n" "Q$n" "-" "-" "not run"
    fi
  done

  echo ""
  echo "Absolute times are specific to this machine and this dataset size."
  echo "The RATIO is the finding; the milliseconds are not portable."
} | tee "$OUT"

#!/usr/bin/env bash
# *******************************************************
# Assembles the generated deliverables from measured output + authored notes.
#
#   usage: build_deliverables.sh [query_analysis|star_schema_queries|all]
#
# The split matters and is deliberate:
#   GENERATED (never hand-typed) - SQL text, result rows, timings, EXPLAIN
#       plans. These come from out/*.txt, written by run_query.sh.
#   AUTHORED  (never machine-guessed) - schema analysis and bottleneck
#       diagnosis. These come from notes/*.txt and are spliced in.
#
# Automating the measurements keeps them honest; automating the conclusions
# would be fabricating them.
#
# Why splice instead of writing deliverables/query_analysis.txt by hand: this
# script OVERWRITES its output, so any analysis typed straight into the
# deliverable would be silently destroyed the next time `make queries` runs.
# Keeping the prose in notes/ means the numbers refresh and the writing
# survives.
# *******************************************************
set -euo pipefail

WHAT="${1:-all}"
cd /work
mkdir -p deliverables

PSQL="psql -U ${PGUSER:-lab} -d ${PGDATABASE:-healthcare}"

# --- extractors -------------------------------------------------------------
# Each pulls one section out of an out/<label>.txt produced by run_query.sh.
# `|| true` on the greps: a missing section is a normal state (e.g. a query
# that hasn't been run yet), not a reason to abort under `set -e`.

sql_of()    { awk '/^--- SQL /{f=1;next} /^--- RESULTS/{f=0} f' "$1"; }
plan_of()   { awk '/^--- QUERY PLAN/{f=1;next} f' "$1"; }
median_of() { awk '/MEDIAN/{print $3; exit}' "$1"; }
exectime_of(){ awk '/Execution Time/{print $3; exit}' "$1"; }
# The root plan node's Buffers line is cumulative, so the FIRST one is the
# whole-query total.
buffers_of(){ awk '/^--- QUERY PLAN/{f=1} f && /Buffers: shared/ {gsub(/^ +/,""); print; exit}' "$1"; }
# Title comes from the source SQL's leading comment, so it is never duplicated
# between the query file and the deliverable.
# The \r strip is deliberate: a CRLF source file leaves the carriage return
# before end-of-line, so /\.$/ silently stops matching and the title keeps a
# stray period plus an invisible ^M. .gitattributes should prevent CRLF ever
# reaching here, but this costs nothing and fails visibly if it does.
title_of() {
  sql_of "$1" | awk '/^-- S?Q[0-9]:/{
      sub(/\r$/, ""); sub(/^-- S?Q[0-9]: */, ""); sub(/\.$/, ""); print; exit }'
}

hdr() {
  printf '%s\n %s\n%s\n\n' \
    "*******************************************************" \
    "$1" \
    "*******************************************************"
}

# --- one question block -----------------------------------------------------
# Emits the assignment's requested layout:
#   QUESTION n / SQL Query / Schema Analysis / Performance / Bottleneck / Plan
emit_question() {
  # Two statements, not one: bash expands every argument to `local` BEFORE it
  # performs any of the assignments, so a single
  #   local label="$2" f="out/${label}.txt"
  # expands ${label} while it is still unset and dies under `set -u`.
  local n="$1" label="$2" notes="$3"
  local f="out/${label}.txt"

  if [ ! -f "$f" ]; then
    echo "QUESTION ${n}: (not run yet - no out/${label}.txt)"
    echo "  Run: make ${label}"
    echo ""
    return
  fi

  echo "------------------------------------------------------------------------------"
  echo "QUESTION ${n}: $(title_of "$f")"
  echo "------------------------------------------------------------------------------"
  echo ""
  echo "SQL Query:"
  sql_of "$f"
  echo ""

  # Authored half. If the notes file is absent, say so loudly rather than
  # emitting a deliverable that silently looks finished.
  if [ -f "$notes" ]; then
    cat "$notes"
  else
    echo "Schema Analysis:"
    echo "  !! ${notes} not written yet - this section is authored, not generated."
    echo ""
    echo "Bottleneck Identified:"
    echo "  !! ${notes} not written yet."
  fi
  echo ""

  # Measured half. Always regenerated, never hand-typed.
  echo "Performance (measured):"
  echo "  - Median execution time : $(median_of "$f") ms   (1 discarded warm-up, median of 3)"
  echo "  - Final run reported    : $(exectime_of "$f") ms"
  echo "  - $(buffers_of "$f")"
  echo ""
  echo "Query plan (EXPLAIN ANALYZE, BUFFERS):"
  plan_of "$f"
  echo ""
}

# --- deliverable builders ---------------------------------------------------
build_query_analysis() {
  {
    hdr "PART 2 - OLTP QUERY ANALYSIS"
    echo "Engine  : PostgreSQL 16 (containerised)"
    echo "Dataset : $($PSQL -At -c 'SELECT count(*) FROM encounters') encounters,"\
         "$($PSQL -At -c 'SELECT count(*) FROM patients') patients"
    echo "Method  : 1 discarded warm-up run, then the median of 3 EXPLAIN ANALYZE runs."
    echo "          Absolute times are machine-specific; the ratios are the finding."
    echo "Source  : SQL, timings and plans generated from out/q*.txt."
    echo "          Schema analysis and bottlenecks authored in notes/."
    echo ""
    for q in 1 2 3 4; do
      emit_question "$q" "q${q}" "notes/q${q}_analysis.txt"
    done
  } > deliverables/query_analysis.txt
  echo ">> deliverables/query_analysis.txt"
}

build_star_queries() {
  {
    hdr "PART 3.3 - STAR SCHEMA QUERIES + PERFORMANCE COMPARISON"
    echo "Each query below answers the same business question as its OLTP"
    echo "counterpart in query_analysis.txt, and is proven to return identical"
    echo "rows by the parity tests in out/test_results.txt."
    echo ""
    for q in 1 2 3 4; do
      emit_question "$q" "sq${q}" "notes/sq${q}_analysis.txt"
    done
    if [ -f out/bench.txt ]; then
      cat out/bench.txt
    else
      echo "!! out/bench.txt missing - run: make bench"
    fi
  } > deliverables/star_schema_queries.txt
  echo ">> deliverables/star_schema_queries.txt"
}

# star_schema.sql is a copy, not a build: the DDL that actually ran IS the
# deliverable, so copying guarantees they can never drift apart.
copy_ddl() {
  if [ -f sql/star/01_star_schema.sql ]; then
    cp sql/star/01_star_schema.sql deliverables/star_schema.sql
    echo ">> deliverables/star_schema.sql  (copied from sql/star/01_star_schema.sql)"
  else
    echo "!! sql/star/01_star_schema.sql missing"
  fi
}

case "$WHAT" in
  query_analysis)      build_query_analysis ;;
  star_schema_queries) build_star_queries ;;
  all)
    build_query_analysis
    build_star_queries
    copy_ddl
    echo ""
    echo "--- hand-written deliverables (this script never overwrites these) ---"
    for f in design_decisions.txt etl_design.txt reflection.md; do
      if [ -f "deliverables/$f" ]; then
        printf '   OK      %-24s %s lines\n' "$f" "$(wc -l < "deliverables/$f")"
      else
        printf '   MISSING %-24s <- yours to write\n' "$f"
      fi
    done
    echo ""
    ls -la deliverables/
    ;;
  *)
    echo "usage: $0 [query_analysis|star_schema_queries|all]" >&2
    exit 2
    ;;
esac

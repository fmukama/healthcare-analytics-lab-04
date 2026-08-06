# `-include` (note the leading dash) means "include this if it exists, but
# don't error if it doesn't" — so `make help` still works before you've run
# `cp .env.example .env`. `export` forwards every variable from .env into the
# environment of every recipe command below (so psql, docker compose, etc.
# all see PGUSER/PGPASSWORD/PGDATABASE/PGPORT automatically).
-include .env
export

# ?= means "set this only if not already set" — lets you override on the
# command line, e.g. `make all SCALE=ci` or `make q1 RUNS=5`, without editing
# this file. Defaults here are deliberately safe even if .env is missing.
PGUSER     ?= lab
PGDATABASE ?= healthcare
COMPOSE    ?= docker compose
DB         ?= db
RUNS       ?= 3

# dev = full-size dataset ; ci = small, fast dataset (see .github/workflows/ci.yml)
# NOTE: comment deliberately kept on its own line above, not trailing on the
# assignment — a trailing `# ...` after `?= dev` would bake trailing spaces
# into $(SCALE) itself (Make does not trim before an inline comment), which
# then silently breaks the `ifeq ($(SCALE),ci)` check below if this default
# is ever edited, and pollutes every echo/log line that prints $(SCALE).
SCALE      ?= dev

# SCALE switches the data volume without touching the SQL generator itself —
# sql/oltp/03_volume.sql just receives whichever numbers land here as psql -v args.
# Patient:encounter ratio is held at 1:10 on purpose. Encounters per patient is
# what creates REPEAT VISITS, and repeat visits are the only reason a 30-day
# readmission exists at all -- generate 70k encounters across 70k patients and
# Q3 correctly reports 0% everywhere, proving nothing.
#
# Scale was chosen by measurement, not by feel. Q3's self-join is quadratic
# (2x the rows costs ~4x the time), so it sets the ceiling for the whole run:
#     encounters :   7,000    30,000    60,000     600,000
#     Q3         :     83ms    1,412ms   5,556ms   >265,000ms
# 600k makes `make all` a ~25-minute job. Below ~30k, Q1 and Q4 drop to single
# digit milliseconds, where their star rewrites land inside run-to-run jitter
# and the "Nx faster" claim stops being defensible. 70k keeps every query
# comfortably above noise while the full pipeline stays in the low minutes.
ifeq ($(SCALE),ci)
  N_PATIENTS   = 700
  N_ENCOUNTERS = 7000
else
  N_PATIENTS   = 7000
  N_ENCOUNTERS = 70000
endif

# Two reusable command prefixes so every target below is a one-liner:
#   PSQL — run a .sql file (or -c "...") against the running container's database
#   RUN  — run an arbitrary shell script (scripts/*.sh) inside the same container
# -T disables pseudo-TTY allocation: required so `make` output pipes/redirects
# cleanly (a TTY would otherwise garble output when Make captures it).
PSQL = $(COMPOSE) exec -T $(DB) psql -U $(PGUSER) -d $(PGDATABASE) -v ON_ERROR_STOP=1
RUN  = $(COMPOSE) exec -T -e PGUSER=$(PGUSER) -e PGDATABASE=$(PGDATABASE) $(DB) bash

# Running `make` with no target runs `help`, not the first target blindly —
# safer default for a control panel with a `nuke` target in it.
.DEFAULT_GOAL := help

# .PHONY tells Make these names are ACTIONS, not files it should check the
# timestamp of. Without this, a stray file literally named `test` or `clean`
# in the working directory would confuse Make into skipping the recipe.
#
# NOTE: q% and sq% (the PATTERN itself), not q1/q2/q3/q4/sq1../sq4 individually.
# Listing the concrete names (e.g. `q1`) in .PHONY makes Make treat that as an
# explicit rule for q1 that overrides the pattern rule below, which then
# prints "make: Nothing to be done for 'q1'" instead of running the recipe.
# Marking the pattern itself phony avoids that trap while still telling Make
# these targets are actions, not files to check timestamps on.
.PHONY: help up down nuke wait shell oltp volume q% queries \
        star etl sq% star-queries bench test docs deliverables \
        verify-ddl all ci clean

help:
	@echo ""
	@echo "  ENVIRONMENT"
	@echo "    make up            start Postgres and wait until healthy"
	@echo "    make down          stop containers (data kept)"
	@echo "    make nuke          stop and DELETE the data volume"
	@echo "    make shell         interactive psql prompt"
	@echo ""
	@echo "  PART 1-2  OLTP"
	@echo "    make oltp          create 3NF schema + load sample rows"
	@echo "    make volume        generate $(N_ENCOUNTERS) encounters (SCALE=$(SCALE))"
	@echo "    make q1 .. q4      run one OLTP query: results + EXPLAIN + timings"
	@echo "    make queries       run q1..q4 and build query_analysis.txt"
	@echo ""
	@echo "  PART 3  STAR SCHEMA"
	@echo "    make star          create dimensions, fact, bridges"
	@echo "    make etl           load star schema from OLTP"
	@echo "    make sq1 .. sq4    run one star query"
	@echo "    make star-queries  run sq1..sq4 and build star_schema_queries.txt"
	@echo "    make bench         side-by-side speedup table"
	@echo ""
	@echo "  QUALITY"
	@echo "    make test          integrity + parity assertions (fails loudly)"
	@echo "    make docs          render docs/*.puml to PNG + SVG"
	@echo "    make deliverables  assemble the 6 graded files"
	@echo "    make verify-ddl    assert the graded DDL is the DDL that runs"
	@echo ""
	@echo "    make all           everything, from zero  <-- the demo command"
	@echo "    make ci            same, small dataset, for CI"
	@echo "    make clean         wipe out/ and logs/ (keeps the database)"
	@echo ""

# ---------- environment 

up:                                    # start (or reuse) the container and BLOCK until its healthcheck passes
	$(COMPOSE) up -d --wait

down:                                  # stop containers; the named `pgdata` volume is untouched, so data survives
	$(COMPOSE) down

nuke:                                  # stop AND delete the data volume — next `make up` starts from a truly empty database
	$(COMPOSE) down -v

shell:                                 # drop into an interactive psql session for poking around by hand
	$(COMPOSE) exec $(DB) psql -U $(PGUSER) -d $(PGDATABASE)

# ---------- OLTP (Part 1) 

oltp: up
	$(PSQL) -f /work/sql/oltp/01_schema.sql
	$(PSQL) -f /work/sql/oltp/02_seed.sql
	@echo ">> OLTP schema + seed loaded"

# `up` prerequisite, not just a bare recipe: without it, `make volume` on a
# stopped container fails with docker's unhelpful `service "db" is not running`
# instead of just starting the database. Same reason `oltp` depends on `up`.
volume: up                            # Phase 2: without this, every query below runs in <1ms and there's no bottleneck to find
	$(PSQL) -v n_patients=$(N_PATIENTS) -v n_encounters=$(N_ENCOUNTERS) \
	        -f /work/sql/oltp/03_volume.sql
	$(PSQL) -c "ANALYZE;"
	@echo ">> volume generated (SCALE=$(SCALE): $(N_PATIENTS) patients / $(N_ENCOUNTERS) encounters)"

# ---------- OLTP queries (Part 2) 
# Pattern rule: `make q3` matches `q%` with $* bound to "3". One recipe covers
# all four questions. The script resolves sql/analysis/q3_*.sql itself.
q%:
	$(RUN) /work/scripts/run_query.sh oltp q$* /work/sql/analysis $(RUNS)

queries: q1 q2 q3 q4
	$(RUN) /work/scripts/build_deliverables.sh query_analysis

# ---------- star schema (Part 3) -

star:
	$(PSQL) -f /work/sql/star/01_star_schema.sql
	$(PSQL) -f /work/sql/star/02_dim_date_load.sql
	@echo ">> star schema created"

etl:
	$(PSQL) -f /work/sql/etl/01_dims.sql
	$(PSQL) -f /work/sql/etl/02_fact.sql
	$(PSQL) -f /work/sql/etl/03_bridges.sql
	$(PSQL) -c "ANALYZE;"
	@echo ">> star schema loaded"

sq%:                                   # same pattern-rule trick as q% above, for the star-schema rewrites
	$(RUN) /work/scripts/run_query.sh star sq$* /work/sql/star_queries $(RUNS)

star-queries: sq1 sq2 sq3 sq4
	$(RUN) /work/scripts/build_deliverables.sh star_schema_queries

bench:                                 # reads out/timings.csv (written by every q%/sq% run) into a speedup table
	$(RUN) /work/scripts/bench.sh

# ---------- quality -----

test:
	$(PSQL) -f /work/tests/00_helpers.sql
	$(RUN) /work/scripts/run_tests.sh

docs:                                  # renders docs/*.puml via the official plantuml image — no local Java/PlantUML install needed
	docker run --rm -v "/$(CURDIR)/docs:/data" plantuml/plantuml -tpng -o rendered "/data/*.puml"
	docker run --rm -v "/$(CURDIR)/docs:/data" plantuml/plantuml -tsvg -o rendered "/data/*.puml"
	@echo ">> diagrams rendered to docs/rendered/"

deliverables:
	$(RUN) /work/scripts/build_deliverables.sh all

# deliverables/star_schema.sql is the ONE deliverable that is a copy rather than
# a build: build_deliverables.sh `cp`s it from sql/star/01_star_schema.sql, so
# the DDL that actually RAN is what gets graded. Both files are committed, and
# nothing in tests/ compares them — so the failure mode is silent. Edit the
# source, forget `make deliverables`, commit, and the graded DDL now describes a
# schema this project no longer builds. Nobody notices until a marker reads it.
#
# This target makes that loud. Deliberately a plain file comparison: no database,
# no container, no psql — so it runs on a bare clone, in a pre-commit hook, or in
# CI. `all` runs it LAST, after `deliverables` has regenerated the copy, so a
# green `make all` is also a proof that the two are in sync.
#
# Byte-identity is the right assertion precisely BECAUSE the copy is verbatim —
# adding a "generated file, do not edit" header to the deliverable would be
# friendlier to a human but would cost this one-line check. .gitattributes pins
# both files to LF, so this never false-alarms on line endings.
verify-ddl:
	@diff -q sql/star/01_star_schema.sql deliverables/star_schema.sql >/dev/null 2>&1 \
	  && echo ">> in sync: deliverables/star_schema.sql == sql/star/01_star_schema.sql" \
	  || { echo ""; \
	       echo "!! STALE DELIVERABLE"; \
	       echo "!! deliverables/star_schema.sql is NOT the DDL that runs."; \
	       echo "!! the graded file describes a schema this project no longer builds."; \
	       echo "!!"; \
	       echo "!!   fix:  make deliverables"; \
	       echo ""; \
	       diff sql/star/01_star_schema.sql deliverables/star_schema.sql | head -20; \
	       echo ""; \
	       exit 1; }

# ---------- pipelines -----
# `all` is the one-command demo: wipes the database, rebuilds everything from
# zero, and ends with the 6 graded files in deliverables/. Reproducibility over
# speed — a grader (or future you) can trust the result came from nothing.
# `clean` first, and it is not cosmetic: out/timings.csv is APPENDED to by every
# q%/sq% run, and bench.sh takes the last row per query. Without clean, a full
# rebuild would silently mix its fresh timings with measurements taken against a
# previous (possibly different-sized) database, and the speedup table would be
# arithmetic on unrelated numbers. If `all` wipes the database for
# reproducibility, it has to wipe the measurements taken against the old one too.
all: clean nuke up oltp volume queries star etl test star-queries bench deliverables verify-ddl
	@echo ""
	@echo "=========================================="
	@echo " DONE. See deliverables/ and out/"
	@echo "=========================================="

ci:                                    # identical pipeline, small dataset — for GitHub Actions (see .github/workflows/ci.yml)
	$(MAKE) SCALE=ci all

clean:                                 # safe to run anytime — deletes only generated output, never the database or deliverables/
	rm -rf out/* logs/*

# Healthcare Analytics: OLTP → Star Schema

A normalized (3NF) hospital database is re-modelled as a dimensional star schema,
and the difference is **measured rather than asserted**. Four business questions
are run against both schemas, timed with `EXPLAIN (ANALYZE, BUFFERS)`, and proven
to return identical answers.

| Query | OLTP | Star | Speedup |
|---|---|---|---|
| Q1 Monthly encounters by specialty | 203.97 ms | 79.56 ms | 2.6× |
| Q2 Top diagnosis-procedure pairs | 1,689.42 ms | 377.42 ms | 4.5× |
| Q3 30-day readmission rate | 16,711.26 ms | 9.40 ms | **1,778×** |
| Q4 Revenue by specialty & month | 93.22 ms | 42.47 ms | 2.2× |

Measured on 70,004 synthetic encounters, median of 3 warm runs. Absolute times
are machine-specific; the ratios are the finding.

## Running it

Only Docker and GNU Make are needed — Postgres runs in a container and every
script executes inside it.

```bash
cp .env.example .env
make all
```

**On Windows, run `make` from Git Bash, not PowerShell.** GNU Make needs a POSIX
shell.

`make all` rebuilds everything from an empty database: load the 3NF schema,
generate 70k encounters, measure the four OLTP queries, build and load the star
schema, run the test suite, measure the four rewrites, and assemble the
deliverables. **It takes roughly 4–5 minutes**, most of it Q3 — the 16-second
self-join is run five times, and that slowness is the point of the exercise.

`make help` lists every target. Useful individually:

```bash
make oltp volume   # 3NF schema + 70k synthetic rows
make q3            # run one query: results, timings, EXPLAIN plan
make star etl      # build and load the warehouse
make test          # 60 assertions - integrity + query parity
make bench         # the speedup table above
```

## The deliverables

All six are in [`deliverables/`](deliverables/):

| File | What it is |
|---|---|
| `query_analysis.txt` | The 4 OLTP queries, timings, plans, and bottleneck analysis |
| `design_decisions.txt` | Grain, dimensions, pre-aggregated measures, bridges — each with the alternative rejected and the cost accepted |
| `star_schema.sql` | Complete DDL (copied verbatim from the DDL that actually runs) |
| `star_schema_queries.txt` | The 4 rewrites, with parity proof and per-query comparison |
| `etl_design.txt` | Load order, the three fan-trap-avoiding techniques, refresh strategy |
| `reflection.md` | Analysis and trade-offs — start here if you only read one |

Timings and query plans in those files are **generated** by `make`, never typed
by hand. The analysis and reasoning are written. Automating measurements keeps
them honest; automating the conclusions would be fabricating them.

## Correctness

A fast query returning a different number than the source is a bug shipped to the
business, so `make test` runs **60 assertions across 15 files** and fails loudly:

- **Grain** — one row per encounter, enforced and asserted
- **Fan trap** — `SUM(diagnosis_count)` equals the source row count exactly
- **Money** — warehouse revenue matches billing *to the cent* ($139,591,191.31)
- **Query parity** — each rewrite proven row-identical via `EXCEPT` in both
  directions, plus row counts and a non-vacuity check
- **Readmission flag** — the pre-computed boolean checked row-by-row against the
  honest self-join across all 70,004 encounters
- **Idempotency** — the ETL re-run inside a transaction, with a content checksum

The parity tests read the *actual shipped query files* off disk, so a test can
never drift from the SQL it claims to verify.

## Layout

```
sql/oltp/          3NF schema, seed, synthetic volume generator
sql/analysis/      the 4 OLTP queries          (Part 2)
sql/star/          star schema DDL + dim_date  (Part 3.2)
sql/etl/           dimensions → fact → bridges (Part 3.4)
sql/star_queries/  the 4 rewrites              (Part 3.3)
tests/             integrity + parity assertions
scripts/           timing harness, benchmark, test runner, deliverable builder
notes/             authored analysis, spliced into the generated deliverables
docs/              guide.md (how the phases fit together), understanding.md, diagrams
out/               generated timings and plans (gitignored)
```

## Notes on the data

There is **no external dataset**. The brief supplies four sample encounters,
which every query answers in under a millisecond — no bottleneck to find, and
zero readmissions, so Q3 would return 0% whether the query worked or not.
`sql/oltp/03_volume.sql` therefore generates 70,000 encounters across 7,000
patients with `setseed(0.42)`, so two runs produce byte-identical data.

Scale was chosen by measuring: Q3's self-join is quadratic, so 600k encounters
makes a full run a ~25-minute job, while below ~30k the smaller queries fall into
run-to-run jitter and the speedup claims stop being defensible.

PostgreSQL 16 is used rather than the brief's MySQL-flavoured DDL — a deliberate
deviation documented as Decision 0, for `EXPLAIN (ANALYZE, BUFFERS)` and `EXCEPT`.

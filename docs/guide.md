# Build Guide — Healthcare OLTP → Star Schema

This guide used to carry every SQL and shell snippet inline. Those now live in
real, running files, so duplicating them here would only let the two drift
apart. What remains is the part a file can't tell you: **why each phase exists,
what it hands to the next one, and the traps that actually bit us.**

Read [understanding.md](understanding.md) for the concepts. Read this for the
shape of the work.

---

## Run it

```bash
make up      # start Postgres, wait for healthy
make all     # everything from zero — the demo command
make help    # every target
```

**On Windows, run `make` from Git Bash, not PowerShell.** GNU Make expects a
POSIX shell; under PowerShell it picks `cmd.exe` and multi-line recipes break
in confusing ways.

`make all` starts with `nuke`, which wipes the database. That's deliberate:
for a graded demo, reproducible beats fast.

---

## The one idea

One schema cannot be great at both jobs.

|  | OLTP (live system) | OLAP (analytics) |
|---|---|---|
| Optimised for | writing safely, no duplication | reading fast, few joins |
| Design rule | normalize (3NF) | denormalize |
| Shape | many small tables, long join chains | one fact table, a ring of dimensions |

Normalization scatters one encounter across six tables, so every query has to
**re-assemble** it. At 4 rows that's free. At 70,000 you pay it on every query,
every day.

**The star schema's bet: spend the time once, during a nightly load, so every
query afterwards is cheap.** That sentence answers half the reflection.

---

## How the phases fit together

Each phase produces the input the next one needs. The order isn't stylistic —
skip one and the next has nothing to work with.

```
1. OLTP schema + seed        sql/oltp/01_schema.sql, 02_seed.sql
        │                    10 tables, 4 sample encounters
        ▼
2. Volume generator          sql/oltp/03_volume.sql
        │                    70k encounters — WITHOUT THIS, NOTHING BELOW WORKS
        ▼
3. Measure the pain          sql/analysis/q1..q4.sql  → query_analysis.txt
        │                    EXPLAIN ANALYZE, median of 3 warm runs
        ▼
4. Design decisions          → design_decisions.txt   (thinking, no code)
        │                    grain, dimensions, measures, bridges
        ▼
5. Star schema DDL           sql/star/01_star_schema.sql, 02_dim_date_load.sql
        │                    builds the empty container
        ▼
6. ETL                       sql/etl/01_dims, 02_fact, 03_bridges → etl_design.txt
        │                    FILLS the container + computes the measures
        ▼
7. Tests                     tests/*.sql  — star answer == OLTP answer
        │
        ▼
8. Rewrite the queries       sql/star_queries/sq1..sq4 → star_schema_queries.txt
        │
        ▼
9. Compare and reflect       make bench → reflection.md
```

Three dependencies worth spelling out, because they're the ones people get
backwards:

- **Phase 2 gates everything.** The brief hands you 4 encounters. Every query
  against them runs in under a millisecond, so Phase 3 has no bottleneck to
  find and Phase 9 has no ratio to compute. The sample data also contains
  *zero* readmissions, so Q3 returns 0% whether your query works or not.
- **Phase 3 must run before Phase 6.** The OLTP timings are the baseline. Once
  the ETL exists, anything that speeds up the source invalidates the
  comparison — which is exactly why the ETL indexes a temp copy of
  `encounters` instead of the real table.
- **Phase 5 only builds the container; Phase 6 fills it.** `make star` creates
  eleven empty tables. `is_readmit_30d`, `total_allowed_amount` and
  `diagnosis_count` don't exist anywhere in the OLTP schema — no query can
  select them. The ETL computes them. Skip Phase 6 and you have a prettier
  schema with identical performance.

---

## What each phase is really for

**Phase 3 — measure.** The mark is for *specific* diagnosis. "Too many joins"
scores nothing; "262,323 intermediate rows from a double many-to-many" scores.
Pull the numbers out of `rows=` and `Buffers:` in the plan. Report the median
of warm runs and say you did — reporting a cold first run is the most common
measurement mistake here.

**Phase 4 — decide.** The mark is for alternatives *considered and rejected*.
"Grain = encounter" is worth little. "Grain = encounter, because a
diagnosis-level grain fan-traps `total_allowed` ×2.5, turning $139.6M into
$349M" is worth a lot. Every decision needs a stated cost.

**Phase 5 — model.** Surrogate keys, real foreign keys, an Unknown (`-1`)
member in every dimension, and a comment on every table. Never a NULL foreign
key: a NULL drops the fact from every inner join, so bad data becomes
invisible; `-1` keeps it countable.

**Phase 6 — load.** Three techniques, each preventing one silent bug:
aggregate the many-side in separate CTEs (or the fan trap multiplies your
money), pre-compute the readmission flag (or Q3 keeps its self-join), and
`LEFT JOIN` + `COALESCE(key, -1)` (or an inner join silently drops facts).

**Phase 7 — prove.** *A fast query that returns a different number than the
source is a bug shipped to the business.* Fast + wrong = zero. `EXCEPT` in both
directions is how you prove parity.

**Phase 9 — reflect.** Honesty and numbers. Name the three separate reasons
the star is faster — fewer joins, pre-computation, a shape built for the
workload — and don't blur them. Then say what you gave up.

### The "why not just add indexes?" question

Answer it before someone asks. Indexes make it cheap to find *a few* rows;
these queries deliberately read *all* of them and aggregate. Q1's OLTP plan
already ignores `idx_encounter_date` and scans sequentially. An index also
can't remove a join or invent a pre-computed count. Index tuning and
dimensional modelling solve different problems.

---

## Traps that actually bit us

Not hypothetical — every one of these cost real debugging time.

**In the brief itself**

1. **Seed insert order is broken.** `billing` is listed before `encounters`,
   violating its own foreign key. Reordered in `02_seed.sql`.
2. **The DDL is MySQL-flavoured.** `DATETIME` → `TIMESTAMP`, inline `INDEX` →
   `CREATE INDEX`. Pick your engine on purpose, not mid-load.
3. **"8 normalized tables" — there are 10.** Worth noticing out loud.
4. **`encounters` has two dates and `billing` a third.** One `date_key` can't
   carry all of them. That's the role-playing dimension problem; plan for it.
5. **`age_group` drifts.** An age band in a dimension rewrites history on
   every reload. Keep `date_of_birth` in the dimension, `age_at_encounter` on
   the fact.

**In the tooling**

6. **Uncorrelated `LATERAL` gets hoisted.** The original volume generator
   picked a provider with `WHERE provider_id = <random>` in a lateral that
   never referenced `g`. Postgres evaluated it *once for the whole statement*,
   and because `random()` re-draws per scanned row the match count was itself
   random — 0 rows (~37% of the time) silently produced `INSERT 0 0`, and 2
   rows collided on the primary key. Even the "lucky" case gave 70,000
   encounters sharing one timestamp and one provider.
7. **`round(double precision, int)` doesn't exist** in Postgres — only
   `round(numeric, int)`. `random()` arithmetic yields double.
8. **`head` + `pipefail` = silent truncation.** `psql | head -30` SIGPIPEs
   psql; exit 141 killed the harness before it ever timed anything. Any result
   set over 30 lines hit this.
9. **`local a="$1" b="$a"` fails under `set -u`.** Bash expands every argument
   to `local` before performing any assignment.
10. **`awk 'print v+0'` truncates to 6 significant digits.** `10375.592 ms`
    printed as `10375.6` in the benchmark table.
11. **`timings.csv` appends, never truncates.** Re-running a query leaves the
    old row behind, so the CSV can quietly mix runs from different dataset
    sizes. `make clean` before a final benchmark.
12. **CRLF breaks the container.** With `core.autocrlf=true` and no
    `.gitattributes`, a fresh clone hands out CRLF shell scripts that die with
    `bad interpreter: /usr/bin/env bash^M`. This only shows up on *someone
    else's* machine — a marker's. Fixed by `.gitattributes` pinning LF.

The general lesson in 6–12: **infrastructure handed to you is not
infrastructure that works.** Run it, then check the result is what the tool
claimed.

---

## Measurement method

Anything you quote as a timing must come from a real run:

- one discarded warm-up (first runs are dominated by cold-cache I/O),
- then the median of 3 `EXPLAIN (ANALYZE, BUFFERS)` runs,
- same container, same tuning, same dataset for OLTP and star.

Expect ±20% between passes on a laptop under Docker. Say so; a single median
quoted as exact is less credible than a range you admit to.

Absolute milliseconds are machine-specific and shouldn't be quoted as
production numbers. **The ratio is the finding.**

---

## Reading a query plan in 60 seconds

Read it inside-out — the deepest indented node runs first.

| You see | It means |
|---|---|
| `Seq Scan` | reading the whole table. Fine for aggregation, fatal for lookups. |
| `Hash Join` | hashes the small side, streams the big side past it. Good. |
| `Nested Loop` with big `loops=` | inner side re-scanned per outer row. Red flag. |
| `rows=` on a node | rows *leaving* that node — where you find the row explosion. |
| `Buffers: shared hit=N` | pages touched. Q3's 8.9M against Q1's 653 is the story. |
| plan `rows=` ≫ actual `rows=` | stale statistics — run `ANALYZE`. |

---

## Where everything lives

```
sql/oltp/        01_schema  02_seed  03_volume
sql/analysis/    q1..q4          ← OLTP queries (Part 2)
sql/star/        01_star_schema  02_dim_date_load
sql/etl/         01_dims  02_fact  03_bridges
sql/star_queries/ sq1..sq4       ← rewrites (Part 3.3)
tests/           parity + integrity assertions
scripts/         run_query  build_deliverables  bench  run_tests
notes/           authored analysis, spliced into query_analysis.txt
deliverables/    ← the six graded files
```

**One SQL statement per file** in `sql/analysis/` and `sql/star_queries/`, and
no trailing semicolon — the harness wraps the file in `EXPLAIN (ANALYZE,
BUFFERS)`, which only works for a single statement.

Timings and plans are **generated**; the analysis is **written**. Automate what
a machine measures better than you; write what requires judgement. Automating
your own conclusions would be fabricating them.

---

## Definition of done

- [ ] I can state my fact table's grain in one sentence.
- [ ] I can explain the fan trap with real numbers from my own data.
- [ ] I know why Q3 got dramatically faster (the flag).
- [ ] I can name a situation where a star schema is the *wrong* choice.
- [ ] All six deliverables exist and are non-empty.
- [ ] `star_schema.sql` runs from scratch on an empty database.
- [ ] Every quoted time came from a real run.
- [ ] Each star query returns **identical rows** to its OLTP original, proven
      by a test.
- [ ] One command reproduces everything from zero.

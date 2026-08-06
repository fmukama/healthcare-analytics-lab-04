# Reflection

**Part 4 — Healthcare OLTP → Star Schema**

70,004 encounters. Median of three warm runs after a discarded warm-up, both
schemas timed in the same session on the same container.

| Query | OLTP | Star | Speedup | Joins (OLTP -> star) |
|---|---|---|---|---|
| Q1 Monthly encounters by specialty | 101.36 ms | 71.25 ms | **1.4x** | 2 chained → 3 independent |
| Q2 Top diagnosis-procedure pairs | 643.81 ms | 206.39 ms | **3.1x** | 3 → 4 (bridges join the fact directly) |
| Q3 30-day readmission rate | 8,701.08 ms | 5.89 ms | **1,477x** | 2 + correlated subquery → 1 |
| Q4 Revenue by specialty & month | 55.10 ms | 18.69 ms | **2.9x** | 3 chained → 2 independent |

Every star query returns **identical rows** to its OLTP original — both `EXCEPT`
directions plus row counts, in `tests/10`–`13`. All 15 test files pass.

---

## 1. Why is the star schema faster?

**Fewer joins, of a different shape.** Chained joins run in sequence because each
one's output feeds the next; star joins are independent, so the planner hashes the
small dimensions and streams the fact past them once. In 3NF an encounter does not
know its own specialty — two hops through `providers`, walked by all 70,004 rows on
every run. On the fact it is one column.

**Pre-computation.** `diagnosis_count`, `total_allowed_amount` and
`is_readmit_30d` are columns, not calculations; Q4 never touches `billing` at all.
Cost moves from query time — paid by every analyst on every run — to load time, paid
once. The whole ETL takes ~16 seconds.

**A shape built for the workload.** `dim_date` stores `year` and `month`, so
`GROUP BY` reads columns instead of calling `date_trunc()` 70,004 times. Keys are
4-byte integers, not `VARCHAR(100)`.

### Q3 is a different kind of win

```
Q3 buffer reads:   OLTP 8,939,200   ->   STAR 2,018      (4,430x fewer pages)
```

~71 GB of logical reads to produce eight rows. The OLTP query re-scans `encounters`
once per inpatient stay — no index on `patient_id`, and a date *range* cannot be
hashed. The star version does not do that work faster; **it does not do it at all.**

That explains the whole table. Q1, Q2 and Q4 had their work made *cheaper*
(1.4–3.1x). Q3 had its work *eliminated* (1,477x). An "average speedup" would hide
the only result that changes what the hospital can do.

### The finding I did not expect: the obvious rewrite was *slower*

The straightforward translation of Q1 measured **241 ms against the OLTP's 151 ms**
— a paired measurement from the development session, which is why neither figure
matches the table above. Two causes, neither visible in a schema diagram:

- **`fact_encounters` is 16 MB where `encounters` is 5 MB** — eleven measures the
  source does not carry. A star schema is not automatically smaller.
- **Postgres has no hash path for `COUNT(DISTINCT)`**, so the one-level rewrite
  still sorted 70,004 rows, now off a wider table.

Two fixes, both modelling technique rather than tuning: `COUNT(DISTINCT)` as a
**two-level aggregation** so both levels hash, and **joining text-carrying
dimensions after the aggregate** so `GROUP BY` runs on 4-byte keys. Buffers went
*up* (653 → 2,023) and it still got faster — not sorting 70,004 rows is what did it.

**A star schema is a set of opportunities, not a guarantee.**

Indexes were not the answer: these queries read *all* rows and aggregate them, so
Q1's OLTP plan correctly ignores `idx_encounter_date`. An index cannot remove a join
or invent a pre-computed count.

---

## 2. Trade-offs

**Gained.** Speed, and more valuably simplicity — Q3 went from a correlated
self-join with three correctness traps to a `GROUP BY` over a boolean. Measures are
additive at this grain, so the fact is safe to hand to someone who has not read the
schema.

**Given up.**

- **Duplication** — `specialty_name` in three places; the warehouse is a second full
  copy of the data.
- **ETL complexity** — strict load order, Unknown members, upserts on natural keys, a
  temp index for the readmission lateral. All of it must be correct or the fast
  answers are wrong.
- **Latency** — the warehouse is as fresh as the last load.
- **Derived data goes stale** — redefine readmission to 45 days and `is_readmit_30d`
  must be *reloaded*. Worse, it depends on the *future*: a stay discharged Monday
  only becomes a readmission when Thursday's return arrives, so incremental loads
  must recompute at least 30 days back.

**Worth it?** Yes, and Q3 settles it: 8.7 s is not an interactive query, and it
scales *quadratically* — 83 ms at 7,000 encounters, 5.6 s at 60,000, over 265 s at
600,000. It stops being viable as history grows. Sixteen seconds of nightly ETL buys
that back permanently.

It would **not** be worth it for single-patient lookups — "MRN001's last visit" is
already instant in 3NF and would only be staler here.

---

## 3. Bridge tables: worth it?

Yes — for containment rather than speed.

**Why not denormalize into the fact?** `diagnosis_1 … diagnosis_N` is a repeating
group: it breaks the first time a patient has N+1 diagnoses, and "find every
encounter with code I10" becomes a scan of every column. **Why not change the
grain?** That is the fan trap — at diagnosis grain each encounter's billing repeats
once per diagnosis, inflating a true \$139.6M into roughly \$349M. Nothing errors;
the numbers are quietly wrong.

**The trade-off.** Q2 stays a many-to-many join and is the one query that does not
become trivial — 3.1x against Q3's 1,477x. But Q1, Q3 and Q4 never touch the bridges,
so the expensive relationship is confined to the only query that needs code-level
detail instead of being paid for by everything.

**In production:** a pre-built `agg_diagnosis_procedure_pairs` summary for Q2 (far
faster, answers exactly one question where the bridge answers any), and
`allocation_factor` (`1.0 / diagnosis_count`) on the diagnosis bridge — Kimball's
weighted bridge — so revenue can split across diagnoses without double counting.

The two bridges are keyed **differently on purpose**: diagnoses on
`(encounter_sk, diagnosis_key)`, because the same ICD-10 code twice in one encounter
is a data-entry error; procedures on a surrogate key with the source
`encounter_procedure_id`, because the same CPT code genuinely *can* recur — two chest
X-rays are two billable events. A composite key there would let
`ON CONFLICT DO NOTHING` swallow the second and `procedure_count` would silently stop
matching the bridge. `tests/08` catches that.

---

## 4. Performance quantification

**Q3 — 30-day readmission rate**

```
Original  : 8,701.08 ms      8,939,200 buffer reads
Optimized :     5.89 ms          2,018 buffer reads
Improvement: 1,477x
```

*Main reason:* the work was eliminated, not accelerated. The correlated `EXISTS`
re-scanned `encounters` once per inpatient stay; `is_readmit_30d` was computed once
in the ETL, so the query became a `GROUP BY` over a boolean on a partial index.

**Q2 — Top diagnosis-procedure pairs**

```
Original  : 643.81 ms      262,323 intermediate rows, 30 MB sort
Optimized : 206.39 ms
Improvement: 3.1x
```

*Main reason:* the hop through `encounters` disappears, joins are on narrow integer
keys, and `COUNT(DISTINCT)` becomes `COUNT(*)` over a pre-deduplicated set — a
`HashAggregate` instead of a `GroupAggregate` fed by a sort of 262,323 rows. The row
explosion (≈3.75 rows per encounter) is inherent to the question.

**Q4 (2.9x) and Q1 (1.4x)** are the modest cases, and their ordering is instructive:
Q4 gains more despite Q1 shedding a sort, because Q4 had more to shed *structurally*
— a whole table plus the longest chain. Q1's remaining cost is a sort, and a sort can
only be made cheaper, never abolished.

### On the honesty of these numbers

The data is synthetic (fixed seed; 2.5 diagnoses and 1.5 procedures per encounter,
88% billed, 12% inpatient), so the milliseconds are not production numbers. Across
repeated full runs the **buffer counts were identical every time** (Q3: 8,939,200),
because pages touched depends on the data and the plan, not machine load. The
milliseconds were not: Q3's OLTP time ranged 8.7–17.3 s, and Q1 has measured
anywhere from 1.4x to 2.0x. So the defensible claims are the *order of magnitude*
and the *buffer counts* — not two significant figures on a 1.4x.

One result to flag rather than let stand as a finding: Q3 reports 30–34% across all
eight specialties, and **that ranking is noise.** The generator assigns providers at
random with no specialty-linked risk; the ~32% baseline is an artifact of uniform
arrivals (1 − e^(−30/73) ≈ 34%). Real hospitals run 15–20%. The query is correct; the
data has no signal for it to find.

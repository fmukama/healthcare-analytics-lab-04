# Reflection

**Part 4 — Healthcare OLTP → Star Schema**

All figures below are measured on a 70,004-encounter dataset, median of three
warm runs after a discarded warm-up, OLTP and star timed in the same session on
the same container. Absolute milliseconds are machine-specific; the ratios are
the finding.

| Query | OLTP | Star | Speedup |
|---|---|---|---|
| Q1 Monthly encounters by specialty | 121.89 ms | 59.79 ms | **2.0×** |
| Q2 Top diagnosis-procedure pairs | 784.99 ms | 231.72 ms | **3.4×** |
| Q3 30-day readmission rate | 8,781.83 ms | 6.72 ms | **1,307×** |
| Q4 Revenue by specialty & month | 49.08 ms | 18.65 ms | **2.6×** |

Every one of those star queries is proven to return **identical rows** to its
OLTP original — both `EXCEPT` directions, plus row counts and a non-vacuity
check, in `tests/10`–`13`. Fast and wrong is worth nothing.

---

## 1. Why is the star schema faster?

Three separate mechanisms. They are worth naming separately, because the four
queries benefit from very different ones and the spread from 2.0× to 1,307×
makes no sense otherwise.

**Fewer joins, and joins of a different shape.** Q4 goes from a four-table chain
(`billing → encounters → providers → specialties`) to a fact plus two dimensions.
The count matters less than the *shape*: chained joins run in sequence because
each one's output feeds the next, whereas star joins are independent, so the
planner hashes the small dimensions and streams the fact past them once. In the
OLTP model an encounter does not know its own specialty — it is two hops away
through `providers`, and all 70,004 rows walk that path on every run. On the fact
it is one column.

**Pre-computation.** `diagnosis_count`, `total_allowed_amount` and
`is_readmit_30d` are columns, not calculations. Q4 never touches `billing` at
all. This is where the cost moves from query time — paid by every analyst on
every run — to load time, paid once, off-hours. The whole ETL takes 16 seconds.

**A shape built for the workload.** `dim_date` stores `year` and `month`, so
`GROUP BY` reads columns instead of calling `date_trunc()` 70,004 times.
Dimensions are small enough to sit in memory. Keys are 4-byte integers, so
aggregating on them is far cheaper than aggregating on a `VARCHAR(100)`.

### Where the speedup actually came from

The headline is Q3, and it is a different kind of win from the others:

```
Q3 buffer reads:   OLTP 8,939,200   →   STAR 2,018      (4,430× fewer pages)
```

Roughly 71 GB of logical reads to produce eight rows. The OLTP query re-scans
`encounters` once per inpatient stay, because there is no index on `patient_id`
and the match is a date *range*, which cannot be hashed. The star version does
not do that work faster — **it does not do it at all**. The flag was computed
during the ETL, so the self-join stopped existing.

That distinction explains the whole table. Q1, Q2 and Q4 had their work made
*cheaper*: 2–3×. Q3 had its work *eliminated*: 1,307×. Quoting an "average
speedup" across the four would be meaningless — it would hide the only result
that actually changes what the hospital can do.

### The finding I did not expect: the obvious rewrite was *slower*

The straightforward translation of Q1 measured **241 ms against the OLTP's
151 ms** in the same session — the star schema *lost*. Q2's naive rewrite was
also slower, 1,126 ms against 1,006 ms.

Two causes, neither visible in a schema diagram:

- **`fact_encounters` is 16 MB where `encounters` is 5 MB.** The fact carries
  eleven measures the source does not. A star schema is not automatically
  smaller — here it is deliberately three times the pages to scan.
- **Postgres has no hash path for `COUNT(DISTINCT)`.** The one-level rewrite
  still sorted all 70,004 rows, now off a wider table. Removing one join did not
  pay for the extra width.

Fixing it took two changes, both dimensional-modelling technique rather than
tuning tricks: rewriting `COUNT(DISTINCT)` as a **two-level aggregation** so both
levels can hash, and **joining the text-carrying dimensions after the
aggregate** so the expensive `GROUP BY` runs on 4-byte keys instead of
`VARCHAR(100)`. That is what turned a loss into Q1's 2.0×.

The lesson I actually take from this lab: *a star schema is a set of
opportunities, not a guarantee.* A wider fact table can be slower than a
narrower normalized one if the query does not exploit what the model offers.

### "Why not just add indexes?"

Because these queries deliberately read **all** the rows and aggregate them. An
index makes it cheap to find *a few* rows. Q1's OLTP plan already ignores
`idx_encounter_date` and does a sequential scan — correctly. An index also
cannot remove a join or invent a pre-computed count. Index tuning and
dimensional modelling solve different problems, and this bottleneck was join
depth and repeated computation, not row lookup.

---

## 2. Trade-offs: what I gained, what I gave up

**Gained.** Query speed, obviously — but the more valuable gain is that the four
business questions became *simple*. Q3 went from a correlated self-join with
three correctness traps (double-counting a patient who returns twice, which
provider's specialty to attribute, whether `>` or `>=`) to a `GROUP BY` over a
boolean. Analysts write less SQL and get fewer chances to get it wrong. Money
and encounter counts are additive at the fact's grain, so the table is safe to
hand to someone who has not read the schema.

**Given up.** Four things, honestly:

- **Data duplication.** `specialty_name` exists in three places. The warehouse is
  a second full copy of the data.
- **ETL complexity.** Three SQL files, a strict load order, Unknown members,
  upserts on natural keys, and a temp index built purely to make the readmission
  lateral affordable. All of it has to be correct or the fast answers are wrong.
- **Latency.** The warehouse is as fresh as the last load. Nightly batch means
  today's encounters are not there yet.
- **Derived data goes stale.** If readmission is redefined from 30 days to 45,
  `is_readmit_30d` must be *reloaded*. No query edit fixes it. Worse, the flag
  depends on the *future* — a stay discharged Monday only becomes a readmission
  when Thursday's return arrives — so incremental loads must recompute at least
  30 days of already-loaded rows, not just insert new ones. That is a subtle,
  easily-missed consequence of pre-computing anything.

**Was it worth it?** For this workload, yes, and Q3 alone settles it: 8.8
seconds is not a query anyone runs interactively, and it scales *quadratically* —
measured at 83 ms for 7,000 encounters, 1.4 s for 30,000, 5.6 s for 60,000, over
265 s for 600,000. It does not merely run slowly today; it stops being viable as
the hospital's history grows. Sixteen seconds of nightly ETL buys that back
permanently.

It would **not** be worth it for a workload of single-patient lookups. "Show me
MRN001's last visit" is already instant in 3NF and would only be staler here.
The star schema is the right answer to *this* question, not to every question —
and being able to say when it is the wrong tool is the part I would want a
reviewer to notice.

---

## 3. Bridge tables: worth it?

Yes, and the reason is containment rather than speed.

**Why not denormalize into the fact?** With grain = encounter you would need
`diagnosis_1 … diagnosis_N` columns. That is a repeating group: it breaks the
first time a patient has N+1 diagnoses, and "find every encounter with code I10"
becomes a scan of every column. **Why not change the grain instead?** That is the
fan trap — at diagnosis grain, each encounter's billing repeats once per
diagnosis, inflating revenue by ~2.5× and turning a true \$139.6M into roughly
\$349M. Nothing errors; the numbers are just quietly wrong.

**The trade-off.** Q2 stays a many-to-many join and is the one query that does
not become trivial — 3.4×, against Q3's 1,307×. But Q1, Q3 and Q4 never touch the
bridges at all. That is the actual win: the expensive relationship is confined to
the only query that genuinely needs code-level detail, instead of being paid for
by everything.

**In production I would do two things differently.** First, add a pre-built
`agg_diagnosis_procedure_pairs` summary table for Q2 — far faster, at the price
of answering exactly one question where the bridge answers any. Second, add
`allocation_factor` (`1.0 / diagnosis_count`) to the diagnosis bridge, Kimball's
weighted-bridge pattern, which would let revenue be split across an encounter's
diagnoses *without* double counting and make "revenue per diagnosis" answerable
from this grain. Nothing in this brief needs it, so I left it out and noted it.

I also keyed the two bridges **differently**, on purpose. The diagnoses bridge is
`PRIMARY KEY (encounter_sk, diagnosis_key)`, because the same ICD-10 code twice
in one encounter is a data-entry error. The procedures bridge uses a surrogate
key with the source `encounter_procedure_id` as its natural key, because the same
CPT code genuinely *can* occur twice — two chest X-rays are two separately
billable events. A composite key there would let `ON CONFLICT DO NOTHING` swallow
the second one and `procedure_count` would silently stop matching the bridge.
`tests/08` exists to catch exactly that.

---

## 4. Performance quantification

**Q3 — 30-day readmission rate**

```
Original  : 8,781.83 ms      8,939,200 buffer reads
Optimized :     6.72 ms          2,018 buffer reads
Improvement: 8781.83 / 6.72 = 1,307x
```

*Main reason:* the work was eliminated, not accelerated. The correlated `EXISTS`
re-scanned `encounters` once per inpatient stay — no index on `patient_id`, and a
date range cannot be hashed. `is_readmit_30d` was computed once during the ETL,
so the query became a `GROUP BY` over a boolean served by a partial index.

**Q2 — Top diagnosis-procedure pairs**

```
Original  : 784.99 ms      262,323 intermediate rows, 30 MB sort
Optimized : 231.72 ms
Improvement: 784.99 / 231.72 = 3.4x
```

*Main reason:* three ordinary gains rather than one structural one — the hop
through `encounters` disappears because both bridges point straight at the fact,
joins are on narrow integer keys, and `COUNT(DISTINCT)` becomes `COUNT(*)` over a
pre-deduplicated set, which lets the plan use a `HashAggregate` where the OLTP
version needs a `GroupAggregate` fed by a sort of 262,323 rows. The row explosion
itself (2.5 diagnoses × 1.5 procedures = 3.75 rows per encounter) does not go
away — it is inherent to the question.

**Q4 — 2.6×** and **Q1 — 2.0×** are the modest cases, and their ordering is
instructive. Q4 gains more despite Q1 shedding an expensive sort, because Q4 had
more to shed *structurally*: a whole table plus the longest join chain in the
lab. Q1's remaining cost is a sort, and a sort can only be made cheaper, never
abolished — which is precisely why Q3, where the work was abolished, is three
orders of magnitude apart from both.

### On the honesty of these numbers

The data is synthetic — 70,000 encounters generated by `sql/oltp/03_volume.sql`
with a fixed seed. That does not invalidate the comparison: the shape and
cardinality are realistic (2.5 diagnoses and 1.5 procedures per encounter, 88% of
encounters billed, 12% inpatient), and both schemas were measured on the same
data, same container, same tuning. What it does mean is that the milliseconds are
not production numbers and should not be quoted as such.

I can put a number on that, because I ran the full pipeline three times on the
same machine. Absolute times moved a great deal between runs — Q3 came out at
17.3 s, 14.7 s and 8.8 s depending on machine load. **The ratios barely moved:**

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| Q1 | 2.0× | 2.0× | 2.0× |
| Q2 | 3.2× | 3.5× | 3.4× |
| Q3 | 1,395× | 1,367× | 1,307× |
| Q4 | 3.1× | 3.1× | 2.6× |

That is the empirical case for reporting ratios rather than milliseconds, and it
is not something I assumed going in — I found it by re-running.

Better still, the **buffer counts were byte-identical every time** (Q3: 8,939,200
on all three runs), because pages touched is a function of the data and the plan,
not of how busy the machine is. Where a claim can be made in buffers instead of
milliseconds, it is the more honest unit — which is why Q3's headline above is
stated both ways.

One result I want to flag rather than let stand as a finding: Q3 reports
readmission rates of 30–34% across all eight specialties, a spread of four
points. **That ranking is noise, not signal.** The generator assigns providers to
encounters at random with no specialty-linked readmission risk, so there is no
real answer to "which specialty is worst" in this dataset. The ~32% baseline is
itself an artifact of uniform arrivals: ten visits over 730 days gives a ~73-day
mean gap, so the chance of a return inside 30 days is roughly
1 − e^(−30/73) ≈ 34% — which is what was measured. Real hospitals run 15–20%. The
query is correct; the data simply has no signal for it to find.

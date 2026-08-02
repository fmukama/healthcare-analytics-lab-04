# Understanding The Lab

## Table of contents

1. [The story in one paragraph](#1-the-story-in-one-paragraph)
2. [The one idea the whole lab is about](#2-the-one-idea-the-whole-lab-is-about)
3. [Vocabulary decoder](#3-vocabulary-decoder-read-this-twice)
4. [The OLTP schema, explained like a hospital](#4-the-oltp-schema-explained-like-a-hospital)
5. [Why the 4 queries hurt](#5-why-the-4-queries-hurt)
6. [What a star schema actually is](#6-what-a-star-schema-actually-is)
7. [What each deliverable really wants](#7-what-each-deliverable-really-wants)
8. [Traps hidden in the assignment](#8-traps-hidden-in-the-assignment-important)
9. [The mental model of your pipeline](#9-the-mental-model-of-your-pipeline)
10. [Your definition of done](#10-your-definition-of-done)

---

## 1. The story in one paragraph

You are a junior data engineer. The hospital's **live system** (the one nurses and doctors type into all day) stores data in a very tidy, no-duplication way. That tidiness is *perfect* for typing in one patient at a time, and *terrible* for questions like "revenue by specialty per month across two years." The analysts complain queries take seconds or minutes. Your job is three-part:

1. **Prove the pain** — write the 4 slow analytical queries, measure them, explain *why* they're slow.
2. **Redesign** — build a second copy of the data shaped for analytics (a **star schema**), with the expensive parts pre-computed.
3. **Prove the win** — rerun the same 4 business questions against the new shape, measure, compare, and reflect honestly on the trade-offs.

That's it. Everything in the assignment PDF is one of those three things.

---

## 2. The one idea the whole lab is about

There are two completely different jobs a database can have, and **one schema cannot be great at both.**

| | **OLTP** (the live system) | **OLAP** (the analytics system) |
|---|---|---|
| Full name | On-Line **Transaction** Processing | On-Line **Analytical** Processing |
| Typical question | "Show me patient MRN001's last visit" | "Average revenue per specialty per month" |
| Rows touched | 1–10 | millions |
| Writes | constant, tiny | rare, huge batches |
| Optimised for | writing safely, no duplication | reading fast, few joins |
| Design rule | **normalize** (3NF) — store each fact once | **denormalize** — repeat data if it saves a join |
| Wins because | integrity, small footprint | fewer joins, pre-computed numbers |
| Shape | many small tables, long join chains | one big fact table + a ring of lookup tables |

**Normalization** = "never store the same thing twice." Great for correctness. But it means information about one encounter is scattered across 6 tables, and to answer a question you must **re-assemble** it every single time you run the query. At 4 rows that's free. At 600,000 rows it's expensive — and you pay it on *every* query, *every* day.

The star schema's bet is: **spend time once (during a nightly load) so every query afterwards is cheap.**

Write that sentence down. It is the answer to half the reflection questions.

---

## 3. Vocabulary decoder (read this twice)

These words will appear in your deliverables. Grading loves correct vocabulary.

| Term | Novice translation |
|---|---|
| **3NF / normalized** | Tidy. No repeated data. Lots of small tables joined by IDs. What Part 1 gives you. |
| **Dimensional model** | The umbrella name for star/snowflake designs. |
| **Fact table** | The big table of *events that happened*, with numbers you can add up. Here: encounters. |
| **Measure / metric** | A number in the fact table you'd `SUM()` or `AVG()`. e.g. `total_allowed`, `diagnosis_count`. |
| **Dimension table** | A small lookup table of *descriptive context* — the who / what / when / where. e.g. `dim_patient`, `dim_date`. |
| **Grain** | **The single most important decision in the lab.** One English sentence: "one row in my fact table = one ______." Everything else follows from it. |
| **Surrogate key** | A meaningless auto-increment integer the warehouse invents (`patient_key = 1, 2, 3…`), used instead of the source system's `patient_id`. Why? So you can keep history, handle sources that reuse IDs, and join on a narrow int. |
| **Natural / business key** | The ID the source system uses (`patient_id`, `mrn`). You keep it in the dimension as a column, but you don't join on it. |
| **Degenerate dimension** | An ID you keep *on the fact table* with no dimension of its own — because it has no attributes worth storing. `encounter_id` is the classic example. Use the term; it looks sharp. |
| **Conformed dimension** | One shared dimension used by many fact tables (`dim_date` is used by everything). Means "Cardiology" means the same thing everywhere. |
| **Star schema** | Fact in the middle, dimensions one hop away. Dimensions are flat and slightly redundant. Every join is 1 hop. |
| **Snowflake schema** | Same, but dimensions are themselves normalized into sub-tables (`dim_provider → dim_specialty`). Tidier, but you're back to join chains. Usually avoided. |
| **Bridge table** | A junction table for a genuine many-to-many between a fact and a dimension (an encounter has *many* diagnoses). It's the star-schema version of `encounter_diagnoses`. |
| **Fan trap / double counting** | The bug you get when you join a one-to-many and then `SUM()`. If an encounter has 3 diagnoses and you join them in, its $10,000 bill gets counted 3 times = $30,000. **This is the #1 trap in this lab.** |
| **SCD (Slowly Changing Dimension)** | How you handle a dimension attribute that changes. *Type 1* = overwrite (lose history). *Type 2* = add a new row with `valid_from`/`valid_to`/`is_current` (keep history). |
| **ETL / ELT** | Extract → Transform → Load. The batch job that copies OLTP → star schema and does the pre-computing. |
| **Idempotent** | Running the load twice produces the same result, not double rows. A requirement for any real pipeline. |
| **Cardinality** | How many rows on each side of a relationship: 1-to-1, 1-to-many, many-to-many. |

---

## 4. The OLTP schema, explained like a hospital

The assignment says "8 normalized tables." **Count them: there are 10.** (Flag this in your write-up — noticing it shows you actually read the schema.)

Here they are in hospital language, grouped by what they are:

**Reference / lookup tables** (rarely change — these become your dimensions)

| Table | In plain English |
|---|---|
| `patients` | One row per human being. Name, DOB, gender, and `mrn` (Medical Record Number — the hospital's unique patient ID). |
| `specialties` | The medical field: Cardiology, Internal Medicine, Emergency. |
| `departments` | A physical unit in the building: name, which floor, how many beds. |
| `providers` | A doctor/clinician. Has a `credential` (MD, DO, NP) and belongs to **one specialty** and **one department**. |
| `diagnoses` | The catalogue of ICD-10 codes. `I10 = Hypertension`. It's a global codebook, not per-patient. |
| `procedures` | The catalogue of CPT codes. `93000 = EKG`. Also a global codebook. |

**Event tables** (grow forever — these become your fact table)

| Table | In plain English |
|---|---|
| `encounters` | **The heart of the schema.** One row per visit. Who (patient), by whom (provider), what kind (`Outpatient` / `Inpatient` / `ER`), when it started (`encounter_date`), when it ended (`discharge_date`), and where (`department_id`). |
| `billing` | The money. One row per insurance claim tied to an encounter. `claim_amount` = what the hospital *asked for*; `allowed_amount` = what the insurer *agreed to pay*. **These are different numbers and the assignment asks for `allowed`.** |

**Junction tables** (resolve many-to-many)

| Table | In plain English |
|---|---|
| `encounter_diagnoses` | "During visit 7001, we diagnosed I10 and E11.9." `diagnosis_sequence = 1` means *primary* diagnosis; 2, 3… are secondary. |
| `encounter_procedures` | "During visit 7001, we performed an Office Visit and an EKG." |

Why do junction tables exist? Because one visit can have many diagnoses, **and** one diagnosis code (Hypertension) appears in many visits. You cannot express that with a single foreign key — so a middle table holds the pairs. That's a **many-to-many**, and it's the reason Query 2 explodes.

> 📐 **See it drawn:** [`docs/01-oltp-erd.puml`](docs/01-oltp-erd.puml)

### The chain that causes all the pain

```
billing → encounters → providers → specialties
                    ↘ patients
                    ↘ departments
                    ↘ encounter_diagnoses → diagnoses
                    ↘ encounter_procedures → procedures
```

Notice: **`encounters` does not know its own specialty.** To learn that an encounter was a cardiology visit, the database must go `encounters → providers → specialties`. Two hops, every row, every query. Remember this — it's the single clearest example of "the OLTP shape forces work."

---

## 5. Why the 4 queries hurt

Each question below has: what's being asked, the join chain, and the *specific* reason it's slow. This maps 1:1 onto `query_analysis.txt`.

> 📐 **See it drawn:** [`docs/02-oltp-join-paths.puml`](docs/02-oltp-join-paths.puml)

### Q1 — Monthly encounters by specialty and encounter type

*"For each month × specialty × encounter type: how many encounters, and how many distinct patients?"*

- **Chain:** `encounters → providers → specialties` (3 tables, 2 joins)
- **Why slow:**
  1. You must scan **every** encounter row — no filter narrows it down, so the `idx_encounter_date` index is useless (an index helps you find *few* rows; here you want *all* of them).
  2. The specialty label is 2 hops away, so every one of 600k rows gets pushed through two joins just to learn one word.
  3. `GROUP BY month` requires deriving the month from a `DATETIME` on the fly — a function on every row.
  4. `COUNT(DISTINCT patient_id)` cannot be done with a running counter; the engine must hold and de-duplicate a set of patient IDs per group. That's memory and sort work.

### Q2 — Top diagnosis–procedure pairs

*"Which diagnosis code + procedure code combinations occur together most often?"*

- **Chain:** `encounter_diagnoses → diagnoses` **and** `encounter_procedures → procedures`, both hanging off `encounters` (4–5 tables)
- **Why slow — and this is the interesting one:** joining **two** many-to-many tables to the same parent creates a **cross product per encounter**. Concretely, with the sample data:

  | encounter | diagnoses | procedures | rows produced |
  |---|---|---|---|
  | 7001 | 2 | 2 | **4** |
  | 7002 | 2 | 1 | 2 |
  | 7003 | 1 | 1 | 1 |
  | 7004 | 1 | 0 | **0** ← dropped by INNER JOIN |

  4 encounters → 7 intermediate rows. Scale that: ~2.5 diagnoses × ~1.5 procedures ≈ **3.75 rows per encounter**, so 600k encounters materialise roughly **2.25M** intermediate rows before you've aggregated anything. (Measure your own ratio in guide.md Phase 2.2 — don't quote mine.)

- ⚠️ **Correctness trap:** because rows are duplicated, `COUNT(*)` is *wrong* if you mean "how many encounters." Use `COUNT(DISTINCT encounter_id)`. Getting this right is worth more marks than getting it fast.
- ⚠️ Also note 7004 vanishing. Decide deliberately: inner join (only encounters that had both) or left join (keep procedure-less encounters)? Say which and why.

### Q3 — 30-day readmission rate by specialty

*"Which specialty most often has patients come back within 30 days of an inpatient discharge?"*

This is the hardest query, and the most clinically real. **Readmission** is a quality-of-care metric — hospitals are financially penalised for high rates.

- **Chain:** `encounters` joined **to itself** (a *self-join*), plus `providers → specialties`
- **The logic:** take encounter `e1` where `encounter_type = 'Inpatient'` (the *index stay*). Look for any other encounter `e2` for the **same patient** whose `encounter_date` is **after** `e1.discharge_date` and **within 30 days** of it. If one exists, `e1` was followed by a readmission.
- **Rate** = (index stays that had a readmission) ÷ (all index stays), grouped by specialty.
- **Why slow:** a self-join on a large table means matching a table against itself. Matching is on `patient_id` (**no index on it** — foreign keys don't create indexes automatically) plus an inequality range on dates. Range conditions can't be hashed, so the engine may end up doing something close to nested loops over a large set. This is the query most likely to take seconds.
- ⚠️ **Correctness traps:**
  - If a patient returns *twice* in 30 days, a naive join counts the index stay twice → rate above 100%. Fix with `EXISTS` or `COUNT(DISTINCT e1.encounter_id)`.
  - Whose specialty — the index stay's provider, or the return visit's? Pick one, **write it down**, defend it. (Convention: the index stay's, since that's the care being judged.)
  - `e2.encounter_date > e1.discharge_date` — strictly greater, or ≥? Does a transfer on the same day count? A sentence of reasoning here reads as professional.

### Q4 — Revenue by specialty and month

*"Total allowed amount per specialty per month."*

- **Chain:** `billing → encounters → providers → specialties` (4 tables, 3 joins) — the assignment names it for you.
- **Why slow:** longest join chain in the lab, plus a `SUM()` over everything, plus a month derivation. Same story as Q1 but one hop worse.
- ⚠️ **Traps:**
  - **Which date?** `billing.claim_date` (when the claim was filed) or `encounters.encounter_date` (when care happened)? These land in different months. There is no single right answer — but there *is* a wrong answer, which is not saying which you chose. Recommended: `encounter_date`, so revenue lines up with clinical activity. State it.
  - **Which amount?** `allowed_amount` (asked for), not `claim_amount`.
  - **Missing billing.** In the sample data only encounters 7001 and 7002 have billing rows. `INNER JOIN` silently drops 7003 and 7004. Is "no claim" the same as "$0 revenue"? Choose, and use `LEFT JOIN` + `COALESCE` if you decide it is.
  - **`claim_status`** — should you count `'Denied'` claims as revenue? Probably not. Nobody told you to filter. Deciding, and saying so, is the mark of an engineer rather than a query typist.

---

## 6. What a star schema actually is

### The analogy

- **OLTP** is a filing cabinet with perfect cross-references. Nothing is duplicated. To write a report you walk to six drawers.
- **Star schema** is a pre-filled ledger. Every row already carries its labels and its totals. You read straight down the page.

You pay for that with disk space and with the nightly job that fills the ledger. That's the trade, and Part 4 asks you to argue it was worth it.

### The shape

```
                  dim_date
                      |
   dim_patient --- fact_encounters --- dim_provider
                   /    |    \
     dim_specialty   dim_dept   dim_encounter_type
                        |
        bridge_encounter_diagnoses → dim_diagnosis
        bridge_encounter_procedures → dim_procedure
```

Everything is **one hop** from the centre. There are no chains. That's the whole geometry, and it's why it's called a star.

> 📐 **See it drawn:** [`docs/03-star-schema.puml`](docs/03-star-schema.puml) and [`docs/04-bridges-detail.puml`](docs/04-bridges-detail.puml)

### The three separate reasons it gets faster

Don't blur these together in your reflection — naming them separately is what earns the marks.

1. **Fewer joins.** Q4 goes from a 4-table chain to `fact + dim_date + dim_specialty`. Chained joins must run in sequence (each one's output feeds the next). Star joins are independent — the engine can hash all the small dimensions and stream the fact table past them once.
2. **Pre-computation.** `diagnosis_count`, `procedure_count` and `total_allowed` are already columns on the fact row. Q2 and Q4 no longer need to visit the junction or billing tables at all. Best of all: if you pre-compute an `is_readmit_30d` flag during ETL, **Q3's self-join disappears entirely** — the hardest query becomes `AVG(flag) GROUP BY specialty`. That's your headline number for Part 4.
3. **A shape built for the workload.** `dim_date` already has a `year_month` column, so `GROUP BY` hits a plain indexed integer instead of computing a function per row. Small dimensions fit in memory. The fact table is narrow integers, so more rows fit per disk page.

### The "why not just add indexes?" question

Somebody will ask it, so answer it before they do — it belongs in your reflection.

> Indexes make it cheap to find **a few** rows out of many. These queries deliberately read **all** the rows and aggregate them; an index doesn't reduce that work, and the planner will correctly ignore it. Indexes also cannot remove a join or invent a pre-computed count. Index tuning and dimensional modelling solve different problems — the star schema wins here because the bottleneck is *join depth and repeated computation*, not row lookup.

Saying that shows you understand *when* a star schema is the wrong answer too, which is the difference between a passing answer and a good one.

---

## 7. What each deliverable really wants

| File | What it literally asks | What's actually being graded |
|---|---|---|
| `query_analysis.txt` | 4 queries + timings + bottleneck | That your **diagnosis** of *why* is specific ("2.7M intermediate rows from a double many-to-many"), not generic ("too many joins"). |
| `design_decisions.txt` | Answers to 4 design questions | That you **considered and rejected** alternatives. "Grain = encounter" scores low. "Grain = encounter, because a diagnosis-level grain would fan-trap `total_allowed` ×2.5" scores high. |
| `star_schema.sql` | Complete DDL | That it actually **runs**, has surrogate PKs, real FKs, sensible indexes, and a comment on every table. |
| `star_schema_queries.txt` | 4 rewrites + comparison | That the rewritten query returns the **same answer** as the original. Fast + wrong = 0. Prove parity. |
| `etl_design.txt` | ETL narrative/pseudocode | That you handle the unglamorous parts: load order, missing dimension keys, re-runs, late-arriving data. |
| `reflection.md` | 1–2 pages | **Honesty and numbers.** Real measured times, and a genuine "what I lost" — not a sales pitch for star schemas. |

**The hidden rubric across all six:** every choice is justified, and every number is measured rather than guessed.

---

## 8. Traps hidden in the assignment (important)

I read the provided material closely. These will bite you if you don't plan for them.

1. **The sample `INSERT` order is broken.** `INSERT INTO billing` appears *before* `INSERT INTO encounters`, but `billing.encounter_id` is a foreign key to `encounters`. Run it as-is on any engine that enforces FKs and it fails. **Reorder your seed file**: `specialties, departments, providers, patients, diagnoses, procedures, encounters, encounter_diagnoses, encounter_procedures, billing`. Mention that you found and fixed it.

2. **The sample data contains zero readmissions.** Check it yourself: patient 1001's only inpatient stay (7002) discharged 2024-06-06 and they never came back; 1002 and 1003 have one encounter each. So Q3 correctly returns **0% for every specialty** — which means you cannot tell a working query from a broken one. You *must* generate more data.

3. **4 rows cannot be slow.** Every query on the seed data will report ~0.5 ms. There is no performance story, no bottleneck to identify, and no improvement factor to compute. **Generating a realistic volume (say 60k patients / 600k encounters) is not optional decoration — it is what makes Parts 2 and 4 possible at all.** This is the single most important practical decision in the lab, and [guide.md](guide.md) Phase 2 shows you how.

4. **Two encounters have no billing rows.** 7003 and 7004 are unbilled. Great — it forces you to make an explicit `INNER` vs `LEFT JOIN` decision, which is exactly what the ETL section means by "how do you handle missing data."

5. **The DDL is MySQL-flavoured.** `INDEX idx_... (...)` inside `CREATE TABLE` is MySQL syntax; PostgreSQL needs a separate `CREATE INDEX`. Also `DATETIME` → `TIMESTAMP`. Pick your engine on purpose (see guide.md, Decision 0) rather than discovering this mid-load.

6. **`floor` and `procedures` are awkward identifiers.** `FLOOR` is a SQL function name and `PROCEDURES` is reserved in some dialects. If your engine complains, double-quote them; don't rename the tables.

7. **`encounters` has two dates, and `billing` has a third.** `encounter_date`, `discharge_date`, `claim_date`. A single `date_key` on your fact table cannot represent all three. This is the **role-playing dimension** problem — you'll want more than one date foreign key. Plan for it in your design rather than patching it later.

8. **`age_group` drifts.** The assignment suggests putting `age_group` in `dim_patient`. But a patient's age changes every year, so "60-69" is only true as-of today — and re-running the load silently rewrites history. Cleaner: keep `date_of_birth` in the dimension and store `age_at_encounter` on the **fact** row, since age-at-time-of-event never changes. Noting this tension is a genuinely strong design-decisions point.

---

## 9. The mental model of your pipeline

This is the flow you're building. Every Make target you'll write maps to one arrow.

```
  ┌──────────────────────┐
  │ 1. OLTP schema+seed  │  10 tables, sample rows (FK order fixed)
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 2. Volume generator  │  ~600k encounters so timings are real
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 3. Run Q1–Q4 (slow)  │  ─────► query_analysis.txt   + logs
  └──────────┬───────────┘        (EXPLAIN ANALYZE, median of 3 runs)
             ▼
  ┌──────────────────────┐
  │ 4. Design decisions  │  ─────► design_decisions.txt  (thinking, no code)
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 5. Star schema DDL   │  ─────► star_schema.sql
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 6. ETL load          │  ─────► etl_design.txt
  │    dims → fact →     │  precompute counts, money, readmit flag
  │    bridges           │
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 7. Tests             │  parity: star answer == OLTP answer
  └──────────┬───────────┘  integrity: no orphan keys, grain is unique
             ▼
  ┌──────────────────────┐
  │ 8. Run Q1–Q4 (fast)  │  ─────► star_schema_queries.txt
  └──────────┬───────────┘
             ▼
  ┌──────────────────────┐
  │ 9. Compare + write   │  ─────► reflection.md
  └──────────────────────┘
```

> 📐 **See it drawn:** [`docs/05-etl-dataflow.puml`](docs/05-etl-dataflow.puml)

**Step 7 is the step most students skip, and it's the one that separates a data engineer from someone who writes SQL.** A fast query that returns a different number than the source is a *bug shipped to the business*. Automating that check is why your Makefile exists.

---

## 10. Your definition of done

Tick these off honestly.

**Understanding**
- [ ] I can say, in one sentence, what my fact table's grain is.
- [ ] I can explain the fan trap with the actual encounter-7001 numbers.
- [ ] I know why my Q3 rewrite is dramatically faster (hint: the flag).
- [ ] I can name one situation where a star schema would be the *wrong* choice.

**Artifacts**
- [ ] All 6 required files exist and are non-empty.
- [ ] `star_schema.sql` runs from scratch on an empty database.
- [ ] Every measured time in my docs came from a real run, not an estimate.
- [ ] Each of my 4 star queries returns **identical rows** to its OLTP original, proven by a test.

**Automation**
- [ ] One Docker command reproduces everything from zero.
- [ ] One Make target per question, printing results to the terminal.
- [ ] Deliverable `.txt` files are generated by code, not hand-typed.
- [ ] Logs are written and kept.
- [ ] Tests exist and fail loudly.
- [ ] CI runs the whole thing on push.

---

**Next:** open [guide.md](guide.md) and start at Phase 0.

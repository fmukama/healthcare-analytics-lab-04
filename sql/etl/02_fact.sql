-- =============================================================================
-- ETL step 2 of 3: fact_encounters.  Grain = one row per encounter.
--
-- This is where the performance win is actually manufactured. Three techniques
-- carry it, and each one exists to prevent a specific, silent bug.
-- =============================================================================
SET search_path = star, public;

-- ---------------------------------------------------------------------------
-- Working copy of encounters, indexed on (patient_id, encounter_date).
--
-- The readmission lookup below asks, for every encounter, "when did this
-- patient next come in?". Against public.encounters that is a scan per row -
-- exactly the cost that makes Q3 take 10.4s and read 8.9M buffers.
--
-- A TEMP table rather than an index on public.encounters, deliberately:
--   * it does not touch the source system, and
--   * it cannot be left behind. An index accidentally left on
--     public.encounters would make a later `make q3` run fast and quietly
--     invalidate the whole OLTP-vs-star comparison.
-- Postgres drops temp objects at session end, so cleanup is guaranteed even
-- if this script fails halfway.
--
-- This is the load-time-versus-query-time trade in miniature: the warehouse
-- can afford an index the transactional system deliberately does not carry,
-- because it pays for it once, off-hours.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _enc AS
SELECT encounter_id, patient_id, encounter_type, encounter_date, discharge_date
FROM public.encounters;
CREATE INDEX ON _enc (patient_id, encounter_date);
ANALYZE _enc;

INSERT INTO fact_encounters (
    encounter_id,
    admit_date_key, discharge_date_key,
    patient_key, provider_key, specialty_key, department_key, encounter_type_key,
    diagnosis_count, procedure_count,
    claim_count, total_claim_amount, total_allowed_amount,
    length_of_stay_hours, age_at_encounter,
    is_inpatient, is_readmit_30d, days_to_next_encounter
)
WITH
-- TECHNIQUE 1: aggregate the many-side FIRST, in its own CTE, then join the
-- one-row-per-encounter result. Joining encounter_diagnoses and billing
-- straight onto encounters and aggregating afterwards is the fan trap:
-- total_allowed_amount would be multiplied by diagnosis_count (x2.5 here).
-- Aggregate first, join second.
dx AS (
    SELECT encounter_id, COUNT(*)::smallint AS diagnosis_count
    FROM public.encounter_diagnoses GROUP BY encounter_id
),
px AS (
    SELECT encounter_id, COUNT(*)::smallint AS procedure_count
    FROM public.encounter_procedures GROUP BY encounter_id
),
bill AS (
    -- The claim_status filter MUST match Q4's. If these two ever disagree the
    -- parity test fails, and the ETL is what is wrong, not the test.
    -- Denied claims are excluded (design_decisions.txt, Supporting Decisions).
    SELECT encounter_id,
           COUNT(*)::smallint    AS claim_count,
           SUM(claim_amount)     AS total_claim_amount,
           SUM(allowed_amount)   AS total_allowed_amount
    FROM public.billing
    WHERE claim_status <> 'Denied'
    GROUP BY encounter_id
)

-- TECHNIQUE 3: LEFT JOIN every dimension, then COALESCE the key to -1.
-- An INNER JOIN would silently DROP any encounter whose dimension lookup
-- failed. Dropping facts is the worst failure mode in a warehouse - the
-- numbers come out wrong and nothing raises an error. LEFT + COALESCE keeps
-- the row and makes the defect countable.
SELECT
    e.encounter_id,
    COALESCE(to_char(e.encounter_date, 'YYYYMMDD')::int, -1),
    COALESCE(to_char(e.discharge_date, 'YYYYMMDD')::int, -1),
    COALESCE(dp.patient_key,        -1),
    COALESCE(dpr.provider_key,      -1),
    -- specialty comes off dim_provider, already resolved there. This is the
    -- column that lets Q1/Q4 reach specialty in one hop.
    COALESCE(dpr.specialty_key,     -1),
    -- the ENCOUNTER's department, not the provider's (they differ for 9.3%
    -- of rows) - see design_decisions.txt, Supporting Decisions.
    COALESCE(dd.department_key,     -1),
    COALESCE(det.encounter_type_key, -1),

    COALESCE(dx.diagnosis_count, 0),
    COALESCE(px.procedure_count, 0),

    -- Unbilled is 0, not NULL: these are additive measures and 0 is the
    -- truthful identity. claim_count = 0 is what still distinguishes
    -- "never billed" from "billed, allowed nothing".
    COALESCE(b.claim_count,          0),
    COALESCE(b.total_claim_amount,   0),
    COALESCE(b.total_allowed_amount, 0),

    ROUND((EXTRACT(epoch FROM (e.discharge_date - e.encounter_date)) / 3600.0)::numeric, 2),
    -- age() rather than subtracting years: the naive version is wrong by up to
    -- a year depending on whether the birthday has passed. This costs nothing
    -- and is simply correct.
    EXTRACT(year FROM age(e.encounter_date, pat.date_of_birth))::smallint,

    (e.encounter_type = 'Inpatient'),

    -- TECHNIQUE 2: pre-compute the readmission flag.
    -- This must be semantically IDENTICAL to Q3's EXISTS clause or the parity
    -- test fails. It is: "the earliest encounter after discharge falls within
    -- 30 days" is equivalent to "some encounter after discharge falls within
    -- 30 days", because any qualifying encounter is >= the minimum.
    --
    -- Chosen over LEAD(encounter_date) OVER (PARTITION BY patient_id ...),
    -- which is cheaper but wrong at the edges: LEAD only inspects the
    -- IMMEDIATELY next encounter, so an overlapping stay that begins before
    -- discharge masks a later qualifying return. Correctness first.
    (e.encounter_type = 'Inpatient'
        AND e.discharge_date IS NOT NULL
        AND nx.next_encounter_date IS NOT NULL
        AND nx.next_encounter_date <= e.discharge_date + INTERVAL '30 days'),

    -- Kept alongside the flag so the 30-day threshold stays auditable and
    -- re-derivable without going back to the source system.
    CASE WHEN nx.next_encounter_date IS NOT NULL
         THEN EXTRACT(day FROM nx.next_encounter_date - e.discharge_date)::int
    END

FROM public.encounters e
LEFT JOIN public.patients   pat ON pat.patient_id      = e.patient_id
LEFT JOIN dim_patient       dp  ON dp.patient_id       = e.patient_id
LEFT JOIN dim_provider      dpr ON dpr.provider_id     = e.provider_id
LEFT JOIN dim_department    dd  ON dd.department_id    = e.department_id
LEFT JOIN dim_encounter_type det ON det.type_name      = e.encounter_type
LEFT JOIN dx ON dx.encounter_id = e.encounter_id
LEFT JOIN px ON px.encounter_id = e.encounter_id
LEFT JOIN bill b ON b.encounter_id = e.encounter_id
LEFT JOIN LATERAL (
    SELECT MIN(n.encounter_date) AS next_encounter_date
    FROM _enc n
    WHERE n.patient_id     =  e.patient_id
      AND n.encounter_id  <>  e.encounter_id
      AND n.encounter_date >  e.discharge_date
) nx ON TRUE

-- Idempotent re-run. EVERY measure must appear in the update list: a column
-- left out here is a bug that only shows up on the SECOND load, as a stale
-- number nobody is looking for.
ON CONFLICT (encounter_id) DO UPDATE
SET admit_date_key         = EXCLUDED.admit_date_key,
    discharge_date_key     = EXCLUDED.discharge_date_key,
    patient_key            = EXCLUDED.patient_key,
    provider_key           = EXCLUDED.provider_key,
    specialty_key          = EXCLUDED.specialty_key,
    department_key         = EXCLUDED.department_key,
    encounter_type_key     = EXCLUDED.encounter_type_key,
    diagnosis_count        = EXCLUDED.diagnosis_count,
    procedure_count        = EXCLUDED.procedure_count,
    claim_count            = EXCLUDED.claim_count,
    total_claim_amount     = EXCLUDED.total_claim_amount,
    total_allowed_amount   = EXCLUDED.total_allowed_amount,
    length_of_stay_hours   = EXCLUDED.length_of_stay_hours,
    age_at_encounter       = EXCLUDED.age_at_encounter,
    is_inpatient           = EXCLUDED.is_inpatient,
    is_readmit_30d         = EXCLUDED.is_readmit_30d,
    days_to_next_encounter = EXCLUDED.days_to_next_encounter,
    load_ts                = now();

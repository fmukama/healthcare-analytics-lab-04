-- Synthetic volume generator. Called with:
--   psql -v n_patients=60000 -v n_encounters=600000 -f 03_volume.sql
--
-- Reproducibility: setseed() fixes random() for this session.
-- Everything added here is CLEARLY SYNTHETIC (names "First12345")

SELECT setseed(0.42);

-- --- extra reference data so GROUP BY has something to chew on --------------
-- 3 specialties makes a boring top-N. Extend to 8. Note this in your write-up.
INSERT INTO specialties (specialty_id, specialty_name, specialty_code)
SELECT g, 'Specialty ' || g, 'SP' || g FROM generate_series(4, 8) g;

INSERT INTO departments (department_id, department_name, floor, capacity)
SELECT g, 'Department ' || g, 1 + (g % 6), 10 + (g % 40) FROM generate_series(4, 12) g;

-- 60 providers spread across all specialties / departments
INSERT INTO providers (provider_id, first_name, last_name, credential, specialty_id, department_id)
SELECT 200 + g,
       'Prov' || g, 'Doc' || g,
       (ARRAY['MD','DO','NP','PA'])[1 + (g % 4)],
       1 + (g % 8),
       1 + (g % 12)
FROM generate_series(1, 60) g;

-- code books: ICD-10 3001..3060, CPT 4001..4040 (contiguous ids matter below)
INSERT INTO diagnoses (diagnosis_id, icd10_code, icd10_description)
SELECT 3000 + g, 'D' || lpad(g::text, 3, '0') || '.0', 'Diagnosis ' || g
FROM generate_series(4, 60) g;

INSERT INTO procedures (procedure_id, cpt_code, cpt_description)
SELECT 4000 + g, (90000 + g)::text, 'Procedure ' || g
FROM generate_series(4, 40) g;

-- --- patients -----------------------------------------------------------
-- ids 2000 .. 1999+n (contiguous, so encounters can pick one with arithmetic)
INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, gender, mrn)
SELECT 1999 + g,
       'First' || g, 'Last' || g,
       DATE '1930-01-01' + (random() * 33000)::int, -- ages ~ 5..95
       CASE WHEN random() < 0.5 THEN 'M' ELSE 'F' END,
       'MRN' || lpad((1999 + g)::text, 9, '0')
FROM generate_series(1, :n_patients) g;

-- --- encounters -----------------------------------------------------------
-- ids from 10000 up, so the seeded 7001..7004 stay recognisable.
-- Types weighted like a real hospital: ~70% Outpatient, ~18% ER, ~12% Inpatient.
-- Length of stay depends on type -> makes discharge_date meaningful for Q3.
INSERT INTO encounters (encounter_id, patient_id, provider_id, encounter_type, encounter_date, discharge_date, department_id)
SELECT
    9999 + g AS encounter_id,
    2000 + (random() * (:n_patients - 1))::int AS patient_id,
    p.provider_id,
    r.etype,
    r.ts AS encounter_date,
    r.ts + CASE r.etype
             WHEN 'Inpatient' THEN (1 + random() * 9) * INTERVAL '1 day'
             WHEN 'ER' THEN (2 + random() * 10) * INTERVAL '1 hour'
             ELSE                  (0.5 + random() * 2) * INTERVAL '1 hour'
           END AS discharge_date,
    -- 90% of the time the encounter happens in the provider's own department,
    -- 10% elsewhere. That 10% is deliberate: it forces you to decide WHICH
    -- department your fact table should attribute the encounter to.
    CASE WHEN random() < 0.90 THEN p.department_id ELSE 1 + (random() * 11)::int END
FROM generate_series(1, :n_encounters) g
-- ONE lateral, and it REFERENCES g. Both details are load-bearing:
--   1. A lateral that does not reference g is uncorrelated, so the planner is
--      free to evaluate it ONCE for the whole statement. Split across three
--      laterals (as ts / etype / provider originally were), every encounter
--      ends up with the same timestamp, the same type and the same provider.
--   2. Picking the provider with `WHERE provider_id = <random expr>` re-draws
--      random() for each provider row scanned, so the match count is itself
--      random: 0 rows (~37%) collapses the whole join to INSERT 0 0, and 2+
--      rows repeats g and violates encounters_pkey. Deriving the id
--      arithmetically matches exactly one provider, every time.
CROSS JOIN LATERAL (
    SELECT
        TIMESTAMP '2024-01-01 00:00:00' + (random() * 730) * INTERVAL '1 day' AS ts,
        CASE WHEN random() < 0.70 THEN 'Outpatient'
             WHEN random() < 0.60 THEN 'ER'
             ELSE 'Inpatient' END AS etype,
        201 + ((g + (random() * 59)::int) % 60) AS provider_pick -- providers are 201..260
) r
JOIN providers p ON p.provider_id = r.provider_pick;

-- --- encounter_diagnoses (1..4 per encounter, mean 2.5) --------------------
-- Trick: pick a random base code, then step by 13 (mod 60). gcd(13,60)=1, so
-- successive steps never repeat -> no duplicate dx within one encounter.
-- (Duplicates would silently break diagnosis_count parity later. Test 6 catches it.)
INSERT INTO encounter_diagnoses (encounter_diagnosis_id, encounter_id, diagnosis_id, diagnosis_sequence)
SELECT 100000 + row_number() OVER (),
       e.encounter_id,
       3001 + ((e.base + (s.i - 1) * 13) % 60), -- diagnoses span 3001..3060
       s.i
FROM (
    SELECT encounter_id,
           (random() * 59)::int AS base,
           1 + (random() * 3)::int AS n -- 1..4, mean 2.5
    FROM encounters WHERE encounter_id >= 10000
) e
CROSS JOIN LATERAL generate_series(1, e.n) AS s(i);

-- --- encounter_procedures (0..3 per encounter, mean 1.5) -------------------
-- ~17% of encounters get ZERO procedures on purpose (like seeded 7004) so your
-- INNER-vs-LEFT JOIN decision in Q2 has real consequences.
INSERT INTO encounter_procedures (encounter_procedure_id, encounter_id, procedure_id, procedure_date)
SELECT 200000 + row_number() OVER (),
       e.encounter_id,
       4001 + ((e.base + (s.i - 1) * 11) % 40), -- procedures span 4001..4040
       e.encounter_date::date
FROM (
    SELECT encounter_id, encounter_date,
           (random() * 39)::int AS base,
           (random() * 3)::int AS n -- 0..3, mean 1.5 (0 ~17% of the time)
    FROM encounters WHERE encounter_id >= 10000
) e
CROSS JOIN LATERAL generate_series(1, e.n) AS s(i)
WHERE e.n > 0;

-- --- billing (~88% of encounters; amounts scale with encounter type) -------
INSERT INTO billing (billing_id, encounter_id, claim_amount, allowed_amount, claim_date, claim_status)
SELECT 300000 + row_number() OVER (),
       e.encounter_id,
       -- ::numeric is required: random() arithmetic yields double precision, and
       -- Postgres only ships round(numeric, int) -- there is no two-argument
       -- round() for double precision.
       round(c.claim::numeric, 2),
       round((c.claim * (0.55 + random() * 0.35))::numeric, 2), -- insurer allows 55-90%
       (e.encounter_date + (1 + random() * 20) * INTERVAL '1 day')::date,
       CASE WHEN random() < 0.80 THEN 'Paid'
            WHEN random() < 0.60 THEN 'Pending'
            ELSE 'Denied' END
FROM encounters e
CROSS JOIN LATERAL (
    SELECT CASE e.encounter_type
             WHEN 'Inpatient' THEN 6000 + random() * 34000
             WHEN 'ER'        THEN 800 + random() * 2200
             ELSE               150 + random() * 450
           END AS claim
) c
WHERE e.encounter_id >= 10000
  AND random() < 0.88; -- 12% unbilled

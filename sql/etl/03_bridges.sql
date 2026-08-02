-- =============================================================================
-- ETL step 3 of 3: bridges.  Must run AFTER the fact - both need encounter_sk.
--
-- Note these use INNER JOIN while the fact load used LEFT JOIN everywhere.
-- That is not an inconsistency, it is the difference in what a missing parent
-- MEANS. A fact row with an unresolvable patient is still a real encounter
-- worth counting, so it loads with patient_key = -1. A bridge row pointing at
-- an encounter that does not exist in the fact table is not a partial record;
-- it is garbage, and it should be dropped. Different data, different rule.
-- =============================================================================
SET search_path = star, public;

-- ---------------------------------------------------------------------------
-- Diagnoses. PK is (encounter_sk, diagnosis_key), so ON CONFLICT DO NOTHING
-- collapses a repeated ICD-10 code within one encounter - which is correct
-- here, because the same diagnosis recorded twice for one visit is a data
-- entry error rather than a second clinical event.
-- ---------------------------------------------------------------------------
INSERT INTO bridge_encounter_diagnoses (encounter_sk, diagnosis_key, diagnosis_sequence)
SELECT f.encounter_sk, dd.diagnosis_key, ed.diagnosis_sequence
FROM public.encounter_diagnoses ed
JOIN fact_encounters f  ON f.encounter_id  = ed.encounter_id
JOIN dim_diagnosis    dd ON dd.diagnosis_id = ed.diagnosis_id
ON CONFLICT (encounter_sk, diagnosis_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Procedures. Keyed on the SOURCE row's encounter_procedure_id, not on
-- (encounter_sk, procedure_key). The same CPT code can legitimately occur
-- twice in one encounter - two chest X-rays are two separately billable
-- events - so a composite key would swallow the second occurrence and
-- fact.procedure_count would stop matching the bridge row count. Conflicting
-- on the source's own identity preserves every occurrence and still makes the
-- load idempotent.
-- ---------------------------------------------------------------------------
INSERT INTO bridge_encounter_procedures (encounter_procedure_id, encounter_sk,
                                         procedure_key, procedure_date_key)
SELECT ep.encounter_procedure_id,
       f.encounter_sk,
       dpr.procedure_key,
       COALESCE(to_char(ep.procedure_date, 'YYYYMMDD')::int, -1)
FROM public.encounter_procedures ep
JOIN fact_encounters f   ON f.encounter_id  = ep.encounter_id
JOIN dim_procedure    dpr ON dpr.procedure_id = ep.procedure_id
ON CONFLICT (encounter_procedure_id) DO NOTHING;

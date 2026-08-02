-- =============================================================================
-- ETL step 1 of 3: dimensions.
--
-- Load order inside this file is not arbitrary:
--   1. Unknown members (key = -1) for every dimension
--   2. Independent dimensions   (specialty, department, patient, encounter
--                                type, diagnosis, procedure)
--   3. dim_provider LAST - it needs specialty_key and department_key to exist
--
-- Every statement is an ON CONFLICT upsert, so re-running this file changes
-- nothing. That is a requirement, not a nicety: the fact table stores
-- surrogate keys, so a TRUNCATE + reload would reassign them and silently
-- re-point every existing fact row at the wrong dimension member.
-- =============================================================================
SET search_path = star, public;

-- ---------------------------------------------------------------------------
-- 1. Unknown members.
--    A fact whose dimension lookup fails still needs a valid NOT NULL foreign
--    key. Pointing it at -1 keeps the row visible and the problem countable;
--    a NULL would drop it from every inner join and hide the defect.
-- ---------------------------------------------------------------------------
INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_name, specialty_code)
VALUES (-1, -1, 'Unknown', 'UNK') ON CONFLICT (specialty_key) DO NOTHING;

INSERT INTO dim_department (department_key, department_id, department_name)
VALUES (-1, -1, 'Unknown') ON CONFLICT (department_key) DO NOTHING;

INSERT INTO dim_patient (patient_key, patient_id, mrn, full_name)
VALUES (-1, -1, 'UNKNOWN', 'Unknown Patient') ON CONFLICT (patient_key) DO NOTHING;

INSERT INTO dim_encounter_type (encounter_type_key, type_name, is_inpatient, is_emergency)
VALUES (-1, 'Unknown', FALSE, FALSE) ON CONFLICT (encounter_type_key) DO NOTHING;

INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description)
VALUES (-1, -1, 'UNK', 'Unknown Diagnosis') ON CONFLICT (diagnosis_key) DO NOTHING;

INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description)
VALUES (-1, -1, 'UNK', 'Unknown Procedure') ON CONFLICT (procedure_key) DO NOTHING;

-- Unknown provider comes after Unknown specialty/department: its own foreign
-- keys have to resolve to something.
INSERT INTO dim_provider (provider_key, provider_id, full_name, credential,
                          specialty_key, specialty_name,
                          department_key, department_name)
VALUES (-1, -1, 'Unknown Provider', 'UNK', -1, 'Unknown', -1, 'Unknown')
ON CONFLICT (provider_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Independent dimensions - SCD Type 1 (overwrite on change).
--    Conflict target is the NATURAL key, so the surrogate key assigned on the
--    first load survives every subsequent run.
-- ---------------------------------------------------------------------------
INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT s.specialty_id, s.specialty_name, s.specialty_code
FROM public.specialties s
ON CONFLICT (specialty_id) DO UPDATE
SET specialty_name = EXCLUDED.specialty_name,
    specialty_code = EXCLUDED.specialty_code,
    load_ts        = now();

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT d.department_id, d.department_name, d.floor, d.capacity
FROM public.departments d
ON CONFLICT (department_id) DO UPDATE
SET department_name = EXCLUDED.department_name,
    floor           = EXCLUDED.floor,
    capacity        = EXCLUDED.capacity,
    load_ts         = now();

INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, full_name,
                         date_of_birth, gender)
SELECT p.patient_id, p.mrn, p.first_name, p.last_name,
       p.first_name || ' ' || p.last_name,
       p.date_of_birth, p.gender
FROM public.patients p
ON CONFLICT (patient_id) DO UPDATE
SET mrn           = EXCLUDED.mrn,
    first_name    = EXCLUDED.first_name,
    last_name     = EXCLUDED.last_name,
    full_name     = EXCLUDED.full_name,
    date_of_birth = EXCLUDED.date_of_birth,
    gender        = EXCLUDED.gender,
    load_ts       = now();

-- Curated list, NOT `SELECT DISTINCT encounter_type FROM encounters`.
-- Deriving reference data from the facts means 'ER' disappears from every
-- report in a period that happens to contain no ER visits. Reference data is
-- declared; it is not inferred from whatever the data happened to contain.
INSERT INTO dim_encounter_type (type_name, is_inpatient, is_emergency)
VALUES ('Outpatient', FALSE, FALSE),
       ('Inpatient',  TRUE,  FALSE),
       ('ER',         FALSE, TRUE)
ON CONFLICT (type_name) DO UPDATE
SET is_inpatient = EXCLUDED.is_inpatient,
    is_emergency = EXCLUDED.is_emergency,
    load_ts      = now();

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description)
SELECT d.diagnosis_id, d.icd10_code, d.icd10_description
FROM public.diagnoses d
ON CONFLICT (diagnosis_id) DO UPDATE
SET icd10_code        = EXCLUDED.icd10_code,
    icd10_description = EXCLUDED.icd10_description,
    load_ts           = now();

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description)
SELECT p.procedure_id, p.cpt_code, p.cpt_description
FROM public.procedures p
ON CONFLICT (procedure_id) DO UPDATE
SET cpt_code        = EXCLUDED.cpt_code,
    cpt_description = EXCLUDED.cpt_description,
    load_ts         = now();

-- ---------------------------------------------------------------------------
-- 3. dim_provider - depends on the two dimensions above.
--    LEFT JOIN + COALESCE(..., -1), never INNER JOIN: a provider with a broken
--    department_id must still load. Dropping the provider row here would drop
--    every one of their encounters from the fact table later, which is silent
--    data loss rather than a visible error.
--    specialty_name / department_name are denormalized copies - see
--    design_decisions.txt Decision 2.
-- ---------------------------------------------------------------------------
INSERT INTO dim_provider (provider_id, first_name, last_name, full_name, credential,
                          specialty_key, specialty_name,
                          department_key, department_name)
SELECT p.provider_id, p.first_name, p.last_name,
       p.first_name || ' ' || p.last_name,
       p.credential,
       COALESCE(ds.specialty_key,  -1),
       COALESCE(ds.specialty_name, 'Unknown'),
       COALESCE(dd.department_key,  -1),
       COALESCE(dd.department_name, 'Unknown')
FROM public.providers p
LEFT JOIN dim_specialty  ds ON ds.specialty_id  = p.specialty_id
LEFT JOIN dim_department dd ON dd.department_id = p.department_id
ON CONFLICT (provider_id) DO UPDATE
SET first_name      = EXCLUDED.first_name,
    last_name       = EXCLUDED.last_name,
    full_name       = EXCLUDED.full_name,
    credential      = EXCLUDED.credential,
    specialty_key   = EXCLUDED.specialty_key,
    specialty_name  = EXCLUDED.specialty_name,
    department_key  = EXCLUDED.department_key,
    department_name = EXCLUDED.department_name,
    load_ts         = now();

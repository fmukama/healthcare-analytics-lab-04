-- Test 3: no NULL foreign keys, and nothing silently parked on Unknown.
--
-- The NULL half is tautological under NOT NULL - kept anyway, so the assertion
-- still documents the rule if a column is ever relaxed. The `= -1` half is the
-- one with teeth: "resolved to Unknown" is not constrained anywhere, and a
-- dimension lookup quietly failing for thousands of rows is exactly the defect
-- the Unknown-member design is meant to make VISIBLE rather than acceptable.
--
-- This is also the precondition that makes make_date(dd.year, dd.month, 1) safe
-- in sq1/sq4: with admit_date_key = -1 those rows would silently bucket into
-- 1900-01 instead of failing.

SELECT lab.expect_zero('fk: no NULL dimension keys on the fact',
       (SELECT count(*) FROM star.fact_encounters
        WHERE admit_date_key IS NULL OR discharge_date_key IS NULL
           OR patient_key IS NULL OR provider_key IS NULL
           OR specialty_key IS NULL OR department_key IS NULL
           OR encounter_type_key IS NULL));

SELECT lab.expect_zero('fk: no fact row resolved to Unknown (-1)',
       (SELECT count(*) FROM star.fact_encounters
        WHERE -1 IN (admit_date_key, discharge_date_key, patient_key, provider_key,
                     specialty_key, department_key, encounter_type_key)));

SELECT lab.expect_zero('fk: no bridge row resolved to Unknown (-1)',
       (SELECT count(*) FROM star.bridge_encounter_diagnoses WHERE diagnosis_key = -1)
     + (SELECT count(*) FROM star.bridge_encounter_procedures
        WHERE procedure_key = -1 OR procedure_date_key = -1));

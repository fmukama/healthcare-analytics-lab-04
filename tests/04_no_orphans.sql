-- Test 4: no orphans, in BOTH directions.
--
-- Foreign keys already enforce the warehouse-internal direction. These assert the
-- directions the constraints cannot cover, because they cross schemas.
--
-- The second assertion is the highest-value one in the whole suite: an ETL bug
-- that drops facts is silent - the numbers come out wrong and nothing errors -
-- and nothing else here would catch it.

SELECT lab.expect_zero('orphan: fact row with no source encounter',
       (SELECT count(*) FROM star.fact_encounters f
        LEFT JOIN public.encounters e ON e.encounter_id = f.encounter_id
        WHERE e.encounter_id IS NULL));

SELECT lab.expect_zero('orphan: source encounter with no fact row  <- drops facts',
       (SELECT count(*) FROM public.encounters e
        LEFT JOIN star.fact_encounters f ON f.encounter_id = e.encounter_id
        WHERE f.encounter_id IS NULL));

SELECT lab.expect_zero('orphan: encounter_diagnoses row with no bridge row',
       (SELECT count(*) FROM public.encounter_diagnoses ed
        JOIN star.fact_encounters f ON f.encounter_id = ed.encounter_id
        JOIN star.dim_diagnosis d ON d.diagnosis_id = ed.diagnosis_id
        LEFT JOIN star.bridge_encounter_diagnoses b
               ON b.encounter_sk = f.encounter_sk AND b.diagnosis_key = d.diagnosis_key
        WHERE b.encounter_sk IS NULL));

SELECT lab.expect_zero('orphan: encounter_procedures row with no bridge row',
       (SELECT count(*) FROM public.encounter_procedures ep
        LEFT JOIN star.bridge_encounter_procedures b
               ON b.encounter_procedure_id = ep.encounter_procedure_id
        WHERE b.encounter_procedure_id IS NULL));

SELECT lab.expect_zero('orphan: bridge row pointing at a missing fact',
       (SELECT count(*) FROM star.bridge_encounter_diagnoses b
        LEFT JOIN star.fact_encounters f USING (encounter_sk)
        WHERE f.encounter_sk IS NULL)
     + (SELECT count(*) FROM star.bridge_encounter_procedures b
        LEFT JOIN star.fact_encounters f USING (encounter_sk)
        WHERE f.encounter_sk IS NULL));

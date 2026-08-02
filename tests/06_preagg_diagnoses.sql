-- Test 6: the fan-trap detector.
--
-- If the ETL had joined the junction tables straight onto encounters instead of
-- pre-aggregating each in its own CTE, these counts would be inflated by the
-- cross product and this fails.
--
-- Totals AND row-level. The totals are the readable headline; the row-level
-- checks are the real test, because a total can match perfectly while individual
-- encounters have each other's counts.

SELECT lab.expect_eq('preagg: sum(diagnosis_count) = count(encounter_diagnoses)',
       (SELECT sum(diagnosis_count) FROM star.fact_encounters),
       (SELECT count(*)             FROM public.encounter_diagnoses));

SELECT lab.expect_eq('preagg: sum(procedure_count) = count(encounter_procedures)',
       (SELECT sum(procedure_count) FROM star.fact_encounters),
       (SELECT count(*)             FROM public.encounter_procedures));

SELECT lab.expect_zero('preagg: diagnosis_count correct on every single encounter',
       (SELECT count(*)
        FROM star.fact_encounters f
        LEFT JOIN (SELECT encounter_id, count(*) AS c
                   FROM public.encounter_diagnoses GROUP BY 1) src
               ON src.encounter_id = f.encounter_id
        WHERE f.diagnosis_count IS DISTINCT FROM COALESCE(src.c, 0)));

SELECT lab.expect_zero('preagg: procedure_count correct on every single encounter',
       (SELECT count(*)
        FROM star.fact_encounters f
        LEFT JOIN (SELECT encounter_id, count(*) AS c
                   FROM public.encounter_procedures GROUP BY 1) src
               ON src.encounter_id = f.encounter_id
        WHERE f.procedure_count IS DISTINCT FROM COALESCE(src.c, 0)));

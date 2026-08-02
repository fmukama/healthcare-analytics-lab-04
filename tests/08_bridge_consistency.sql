-- Test 8: bridges agree with the fact's pre-computed counts.
--
-- This is the test sql/star/01_star_schema.sql points at when it explains why
-- bridge_encounter_procedures uses a surrogate key instead of
-- (encounter_sk, procedure_key): a composite key would let ON CONFLICT DO NOTHING
-- swallow a legitimately repeated CPT code, and the swallowed row shows up HERE
-- as a bridge count lower than the fact's procedure_count.

SELECT lab.expect_zero('bridge: dx rows per encounter = fact.diagnosis_count',
       (SELECT count(*)
        FROM star.fact_encounters f
        LEFT JOIN (SELECT encounter_sk, count(*) AS c
                   FROM star.bridge_encounter_diagnoses GROUP BY 1) b
               ON b.encounter_sk = f.encounter_sk
        WHERE f.diagnosis_count IS DISTINCT FROM COALESCE(b.c, 0)));

SELECT lab.expect_zero('bridge: px rows per encounter = fact.procedure_count',
       (SELECT count(*)
        FROM star.fact_encounters f
        LEFT JOIN (SELECT encounter_sk, count(*) AS c
                   FROM star.bridge_encounter_procedures GROUP BY 1) b
               ON b.encounter_sk = f.encounter_sk
        WHERE f.procedure_count IS DISTINCT FROM COALESCE(b.c, 0)));

SELECT lab.expect_eq('bridge: total dx rows = source encounter_diagnoses',
       (SELECT count(*) FROM star.bridge_encounter_diagnoses),
       (SELECT count(*) FROM public.encounter_diagnoses));

SELECT lab.expect_eq('bridge: total px rows = source encounter_procedures',
       (SELECT count(*) FROM star.bridge_encounter_procedures),
       (SELECT count(*) FROM public.encounter_procedures));

-- is_primary is a GENERATED column; assert it tracks diagnosis_sequence so the
-- "primary diagnosis" flag can be trusted by downstream reports.
SELECT lab.expect_zero('bridge: is_primary matches diagnosis_sequence = 1',
       (SELECT count(*) FROM star.bridge_encounter_diagnoses
        WHERE is_primary IS DISTINCT FROM (diagnosis_sequence = 1)));

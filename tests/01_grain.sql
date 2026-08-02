-- Test 1: grain. "One row per encounter" must be true, not just intended.
-- Catches an ETL join that fanned out.

SELECT lab.expect_eq('grain: fact rows = distinct encounter_id',
       (SELECT count(*)                     FROM star.fact_encounters),
       (SELECT count(DISTINCT encounter_id) FROM star.fact_encounters));

SELECT lab.expect_zero('grain: no duplicate encounter_id',
       (SELECT count(*) FROM (
          SELECT encounter_id FROM star.fact_encounters
          GROUP BY 1 HAVING count(*) > 1) x));

-- This one licenses SUM(f.encounter_count) in sq1. If encounter_count were ever
-- anything but 1, that substitution for COUNT(*) would silently change the answer.
SELECT lab.expect_zero('grain: encounter_count is always 1',
       (SELECT count(*) FROM star.fact_encounters WHERE encounter_count <> 1));

-- Duplicates the UNIQUE constraints on purpose: these are the assertions that
-- document the intent and survive a constraint being dropped in a refactor.
SELECT lab.expect_zero('grain: diagnosis bridge unique per (encounter, diagnosis)',
       (SELECT count(*) FROM (
          SELECT encounter_sk, diagnosis_key FROM star.bridge_encounter_diagnoses
          GROUP BY 1,2 HAVING count(*) > 1) x));

SELECT lab.expect_zero('grain: procedure bridge unique per source row',
       (SELECT count(*) FROM (
          SELECT encounter_procedure_id FROM star.bridge_encounter_procedures
          GROUP BY 1 HAVING count(*) > 1) x));

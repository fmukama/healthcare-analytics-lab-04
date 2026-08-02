-- Test 14: the pre-computed readmission flag, checked ROW BY ROW.
--
-- Strictly stronger than test 12, which compares 8 aggregated rows where two
-- opposite errors could cancel out. This compares every one of the fact table's
-- booleans against the honest OLTP EXISTS predicate.
--
-- It is the assertion that licenses the entire Q3 speedup. is_readmit_30d is
-- DERIVED data: if it drifts from the source definition, sq3 returns a fast,
-- confident, wrong answer - and nothing else in the suite would notice.
--
-- The ETL computes it as MIN(next encounter after discharge) <= discharge + 30d;
-- Q3 asks EXISTS(some encounter in that window). Those are the same predicate,
-- because any qualifying encounter is >= the minimum. This proves it rather than
-- relying on the argument.
--
-- Also ~10s: the correlated subquery is the OLTP cost, by design.

SELECT lab.expect_zero('readmit: flag matches the OLTP self-join on every encounter',
       (SELECT count(*)
        FROM star.fact_encounters f
        JOIN public.encounters e ON e.encounter_id = f.encounter_id
        WHERE f.is_readmit_30d IS DISTINCT FROM (
              e.encounter_type = 'Inpatient'
              AND e.discharge_date IS NOT NULL
              AND EXISTS (SELECT 1 FROM public.encounters e2
                          WHERE e2.patient_id     =  e.patient_id
                            AND e2.encounter_id  <>  e.encounter_id
                            AND e2.encounter_date >  e.discharge_date
                            AND e2.encounter_date <= e.discharge_date + INTERVAL '30 days'))));

SELECT lab.expect_zero('readmit: is_inpatient matches encounter_type',
       (SELECT count(*)
        FROM star.fact_encounters f
        JOIN public.encounters e ON e.encounter_id = f.encounter_id
        WHERE f.is_inpatient IS DISTINCT FROM (e.encounter_type = 'Inpatient')));

-- Sanity floor: if the flag were never set, every assertion above would still
-- pass on a dataset with no readmissions - and Q3 would prove nothing. This
-- fails if the generator ever produces a dataset where Q3 is vacuous.
SELECT lab.expect_eq('readmit: dataset actually contains readmissions',
       (SELECT (count(*) > 0)::int FROM star.fact_encounters WHERE is_readmit_30d), 1);

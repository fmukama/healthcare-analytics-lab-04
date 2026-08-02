-- SQ2: Top diagnosis-procedure pairs.
-- Star rewrite of sql/analysis/q2_dx_px_pairs.sql.
-- Proven row-identical over the FULL 2,400-pair result, both EXCEPT directions,
-- by tests/11_parity_q2.sql.
--
-- The LIMIT 20 slice is deliberately NOT asserted row-for-row, and that is a
-- property of the QUESTION rather than of either schema: 13 pairs sit strictly
-- above the cut, 8 are tied at exactly 140, and only 7 slots remain. Eight
-- different top-20s are therefore all equally correct. The test proves what is
-- actually well defined - the whole 2,400-pair population, the cut value, the
-- vector of 20 counts, and the 13 rows above the cut.
--
-- This is the one query that does NOT become trivial in the star schema; it is
-- still a many-to-many join. It gets faster for three ordinary reasons - the
-- bridges are narrow and indexed, the keys are 4-byte integers rather than
-- varchars, and the hop through `encounters` disappears because both bridges
-- point straight at the fact. 1006ms -> 373ms, not the ~1700x that Q3 sees.
--
-- COUNT(DISTINCT) is replaced by COUNT(*) over a pre-deduplicated procedure set.
-- That is exact rather than an approximation, and it is the BRIDGE DESIGN that
-- makes it safe: bridge_encounter_diagnoses is keyed on (encounter_sk,
-- diagnosis_key) so it already holds at most one row per encounter+diagnosis.
-- bridge_encounter_procedures deliberately is not - it preserves repeat CPT
-- codes, which are real separately billable events - so it is deduplicated here
-- instead. With both sides unique per encounter the join emits exactly one row
-- per (encounter, diagnosis, procedure) triple, so COUNT(*) IS the
-- distinct-encounter count, without the sort COUNT(DISTINCT) would force.
SELECT
    dd.icd10_code,
    dd.icd10_description,
    dp.cpt_code,
    dp.cpt_description,
    COUNT(*) AS encounter_count
FROM star.bridge_encounter_diagnoses bed
JOIN star.dim_diagnosis dd ON dd.diagnosis_key = bed.diagnosis_key
JOIN (
    -- No-op on the current dataset (no encounter repeats a CPT), but load
    -- bearing: the procedures bridge is DESIGNED to permit repeats, and without
    -- this a single repeat would inflate COUNT(*) past the true encounter count.
    SELECT DISTINCT encounter_sk, procedure_key
    FROM star.bridge_encounter_procedures
) bep ON bep.encounter_sk = bed.encounter_sk
JOIN star.dim_procedure dp ON dp.procedure_key = bep.procedure_key
GROUP BY 1, 2, 3, 4
ORDER BY encounter_count DESC
LIMIT 20

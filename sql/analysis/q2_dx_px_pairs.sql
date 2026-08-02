-- Q2: Top diagnosis-procedure pairs.
-- Joins: encounter_diagnoses -> diagnoses, encounter_procedures -> procedures,
-- both hanging off encounters via encounter_id (4 tables, 3 joins).
--
-- Row explosion: joining two many-to-many tables to the same encounter builds
-- a cross product per encounter (2 dx x 2 px -> 4 rows before GROUP BY). So
-- COUNT(*) over the whole join is NOT "how many encounters". Once grouped
-- down to one (icd10_code, cpt_code) pair though, an encounter contributes at
-- most one row per pair here (no encounter repeats a dx or px code -- see
-- 03_volume.sql's step-by-coprime-number generation). We still write
-- COUNT(DISTINCT ed.encounter_id), not COUNT(*): it means "encounters with
-- this pair" by definition, and doesn't quietly break if that no-duplicates
-- guarantee ever stops holding.
--
-- INNER JOIN to encounter_procedures is deliberate: an encounter with zero
-- procedures has no diagnosis-procedure PAIR to contribute, so dropping it
-- here is correct -- unlike Q4, this isn't a missing-data problem.
SELECT
    d.icd10_code,
    d.icd10_description,
    pr.cpt_code,
    pr.cpt_description,
    COUNT(DISTINCT ed.encounter_id) AS encounter_count
FROM encounter_diagnoses  ed
JOIN diagnoses            d  ON d.diagnosis_id  = ed.diagnosis_id
JOIN encounter_procedures ep ON ep.encounter_id = ed.encounter_id
JOIN procedures           pr ON pr.procedure_id = ep.procedure_id
GROUP BY 1, 2, 3, 4
ORDER BY encounter_count DESC
LIMIT 20

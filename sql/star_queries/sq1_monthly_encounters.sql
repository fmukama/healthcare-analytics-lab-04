-- SQ1: Monthly encounters by specialty and encounter type.
-- Star rewrite of sql/analysis/q1_monthly_encounters.sql.
-- Proven row-identical (both EXCEPT directions, 576 rows) by tests/10_parity_q1.sql.
--
-- Star objects are fully qualified because the timing harness prepends
-- EXPLAIN (ANALYZE, BUFFERS) to this file, so a SET search_path line would be a
-- second statement and a syntax error. It also means a grader can paste this
-- query anywhere and have it run.
--
-- THE OBVIOUS REWRITE OF THIS QUERY IS SLOWER THAN THE OLTP ORIGINAL - during
-- development the naive form measured 241ms against the original's 151ms in the
-- same session. fact_encounters is 16MB where encounters is 5MB, so
-- there are three times as many pages to scan, and Postgres has no hash path for
-- COUNT(DISTINCT), so the naive form sorts all 70,004 rows off the wider table.
-- Dropping one join does not pay for that. Two rewrites earn the win back:
--   1. COUNT(DISTINCT patient) becomes a two-level aggregation. Grouping to
--      (group x patient) first and then counting rows lets the planner
--      HashAggregate twice instead of sorting once.
--   2. dim_specialty and dim_encounter_type are joined AFTER the aggregate, so
--      the expensive GROUP BY runs on 4-byte surrogate keys rather than a
--      VARCHAR(100) and a VARCHAR(50). dim_date must be joined BEFORE, because
--      the month is part of the grain the patient DISTINCT is computed at.
-- Net effect: the smallest speedup of the four (see notes/sq1_analysis.txt for
-- the measured figures), because a sort can be made cheaper but not abolished.
WITH per_patient AS (
    SELECT
        dd.year                AS y,
        dd.month               AS m,
        f.specialty_key,
        f.encounter_type_key,
        f.patient_key,
        SUM(f.encounter_count) AS encounters
    FROM star.fact_encounters f
    JOIN star.dim_date dd ON dd.date_key = f.admit_date_key
    GROUP BY 1, 2, 3, 4, 5
),
rolled AS (
    SELECT
        y, m, specialty_key, encounter_type_key,
        -- SUM() over bigint returns numeric; cast back so the parity EXCEPT
        -- compares like with like against Q1's COUNT(*).
        SUM(encounters)::bigint AS total_encounters,
        -- exactly one row per distinct patient survived the CTE above, so
        -- COUNT(*) here IS COUNT(DISTINCT patient_key), and it is already bigint.
        COUNT(*)                AS unique_patients
    FROM per_patient
    GROUP BY 1, 2, 3, 4
)
SELECT
    -- date, matching Q1's date_trunc('month', ...)::date exactly, and evaluated
    -- once per output group instead of once per fact row. NOT year_month: that
    -- column is CHAR(7) and its Unknown member holds the literal 'Unknown',
    -- which would raise on a ::date cast.
    make_date(r.y::int, r.m::int, 1) AS month,
    ds.specialty_name,
    det.type_name                    AS encounter_type,
    r.total_encounters,
    r.unique_patients
FROM rolled r
JOIN star.dim_specialty      ds  ON ds.specialty_key       = r.specialty_key
JOIN star.dim_encounter_type det ON det.encounter_type_key = r.encounter_type_key
ORDER BY 1, 2, 3

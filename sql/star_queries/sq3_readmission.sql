-- SQ3: 30-day readmission rate by specialty.
-- Star rewrite of sql/analysis/q3_readmission.sql.
-- Proven row-identical (both EXCEPT directions, 8 rows) by tests/12_parity_q3.sql,
-- and the underlying flag is proven row-by-row against the OLTP self-join across
-- all 70,004 encounters by tests/14_readmission_flag.sql.
--
-- THE HEADLINE. Q3's correlated EXISTS over 70,004 encounters is gone entirely:
-- is_readmit_30d was computed once during the ETL, so this collapses to a GROUP
-- BY over a boolean served by the partial index idx_fact_inpatient.
-- 10,376ms -> 6ms. The self-join was not optimised; it stopped existing.
--
-- Cohort translation, term for term:
--     encounter_type = 'Inpatient'   ->  f.is_inpatient
--     discharge_date IS NOT NULL     ->  f.discharge_date_key <> -1
-- The ETL maps a NULL discharge to the dim_date Unknown member (-1). That is 0
-- rows today, so the second predicate changes nothing - but without it this
-- stops being a translation of Q3 the moment one open stay exists, and it would
-- fail silently rather than loudly.
--
-- The rate expression is copied VERBATIM from Q3, 100.0 and NULLIF included.
-- Not cargo-culting: the 100.0 literal is what makes the division numeric, and
-- reassociating or "simplifying" it changes the numeric scale - which makes
-- EXCEPT report a difference between two numbers that print identically.
SELECT
    ds.specialty_name,
    COUNT(*)                                            AS index_stays,
    SUM(CASE WHEN f.is_readmit_30d THEN 1 ELSE 0 END)   AS readmissions,
    ROUND(100.0 * SUM(CASE WHEN f.is_readmit_30d THEN 1 ELSE 0 END)
                / NULLIF(COUNT(*), 0), 2)               AS readmission_rate_pct
FROM star.fact_encounters f
JOIN star.dim_specialty ds ON ds.specialty_key = f.specialty_key
WHERE f.is_inpatient
  AND f.discharge_date_key <> -1
GROUP BY 1
ORDER BY readmission_rate_pct DESC

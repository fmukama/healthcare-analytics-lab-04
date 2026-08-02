-- SQ4: Revenue by specialty and month.
-- Star rewrite of sql/analysis/q4_revenue.sql.
-- Proven row-identical (both EXCEPT directions, 192 rows) by tests/13_parity_q4.sql.
--
-- `billing` does not appear in this query at all - total_allowed_amount is
-- already a column on the fact. Q4's four-table chain
-- (billing -> encounters -> providers -> specialties) becomes fact + 2 dims.
-- 66ms -> 36ms.
--
-- Two things make this an exact translation rather than a near-enough one.
--
-- 1. claim_count. Q4's COUNT(*) counts BILLING ROWS, not encounters. The fact is
--    at encounter grain, so the equivalent is SUM(f.claim_count) - and the ETL
--    applied the same claim_status <> 'Denied' filter when building that column,
--    which is why no status predicate appears here. SUM(smallint) returns
--    bigint, exactly what COUNT(*) returns, so EXCEPT needs no cast.
--    tests/07 carries a negative control proving that filter is genuinely
--    applied and not accidentally a no-op on both sides.
--
-- 2. WHERE f.claim_count > 0. Q4 is anchored on billing (FROM billing b JOIN
--    encounters), so a (month, specialty) with no payable claim produces NO ROW
--    there. The fact holds a row for every encounter, billed or not, so without
--    this predicate the star emits that group with total_allowed = 0. The SUMS
--    are identical either way, because unbilled rows carry 0 - the additive
--    identity. What this predicate controls is group EXISTENCE, nothing else,
--    which is exactly why it is easy to omit and quietly return 193 rows.
--
-- dim_specialty is joined after the aggregate so the GROUP BY runs on a 4-byte
-- key instead of a VARCHAR(100).
WITH agg AS (
    SELECT
        dd.year  AS y,
        dd.month AS m,
        f.specialty_key,
        SUM(f.total_allowed_amount) AS total_allowed,
        SUM(f.claim_count)          AS claim_count
    FROM star.fact_encounters f
    JOIN star.dim_date dd ON dd.date_key = f.admit_date_key
    WHERE f.claim_count > 0
    GROUP BY 1, 2, 3
)
SELECT
    make_date(a.y::int, a.m::int, 1) AS month,
    ds.specialty_name,
    a.total_allowed,
    a.claim_count
FROM agg a
JOIN star.dim_specialty ds ON ds.specialty_key = a.specialty_key
ORDER BY a.total_allowed DESC

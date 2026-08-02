-- Q4: Revenue by specialty and month.
-- Chain: billing -> encounters -> providers -> specialties (4 tables, 3 joins),
-- exactly as the assignment names it.
--
-- Decision (a) date: encounter_date, not billing.claim_date -- revenue lines
-- up with when the care happened, not when the claim was filed weeks later.
-- Decision (b) amount: allowed_amount (what the insurer agreed to pay), not
-- claim_amount (what the hospital asked for).
-- Decision (c) 'Denied' claims are excluded -- the insurer isn't paying
-- allowed_amount on those, so counting them overstates revenue. 'Pending' is
-- kept: allowed_amount is the contractually agreed figure, so it's legitimate
-- expected revenue even before cash is actually collected.
-- Decision (d) INNER JOIN billing -> encounters, not LEFT: this query is
-- anchored on billing by definition (it's a revenue question) -- an encounter
-- that was never billed has no allowed_amount to sum, so starting FROM
-- billing loses nothing here. (LEFT JOIN + COALESCE(...,0) would matter for a
-- different metric, e.g. "average revenue per encounter" -- not this one.)
SELECT
    date_trunc('month', e.encounter_date)::date AS month,
    s.specialty_name,
    SUM(b.allowed_amount) AS total_allowed,
    COUNT(*)              AS claim_count
FROM billing b
JOIN encounters  e ON e.encounter_id = b.encounter_id
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
WHERE b.claim_status <> 'Denied'
GROUP BY 1, 2
ORDER BY total_allowed DESC

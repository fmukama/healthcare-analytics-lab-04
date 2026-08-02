-- Test 7: money. Double-counted revenue is the most expensive possible bug here.
--
-- The Denied-claim filter must be identical in the ETL's billing CTE and in Q4.
-- If it ever diverges, the parity test fails and the ETL is what is wrong.

SELECT lab.expect_eq('money: sum(total_allowed_amount) = non-denied billing',
       (SELECT sum(total_allowed_amount) FROM star.fact_encounters),
       (SELECT sum(allowed_amount) FROM public.billing WHERE claim_status <> 'Denied'));

SELECT lab.expect_eq('money: sum(total_claim_amount) = non-denied billing',
       (SELECT sum(total_claim_amount) FROM star.fact_encounters),
       (SELECT sum(claim_amount) FROM public.billing WHERE claim_status <> 'Denied'));

SELECT lab.expect_eq('money: sum(claim_count) = non-denied billing rows',
       (SELECT sum(claim_count) FROM star.fact_encounters),
       (SELECT count(*) FROM public.billing WHERE claim_status <> 'Denied'));

-- NEGATIVE CONTROL, and the reason this file earns its place.
-- Every assertion above would still pass if the Denied filter were missing from
-- BOTH the ETL and Q4 - they would agree with each other and both be wrong. This
-- asserts the filter actually removes something, i.e. that the three checks above
-- are testing a real behaviour rather than a no-op. It fails loudly if someone
-- deletes `WHERE claim_status <> 'Denied'` from the ETL.
SELECT lab.expect_zero('money: NEGATIVE CONTROL - denied claims really are excluded',
       (SELECT CASE WHEN (SELECT count(*) FROM public.billing WHERE claim_status = 'Denied') = 0
                    THEN 0   -- no denied claims in this dataset; nothing to prove
                    WHEN (SELECT sum(total_allowed_amount) FROM star.fact_encounters)
                         = (SELECT sum(allowed_amount) FROM public.billing)
                    THEN 1   -- fact total equals the UNFILTERED total => filter not applied
                    ELSE 0
               END));

-- Row level: every encounter's stored money must match its own claims.
SELECT lab.expect_zero('money: total_allowed_amount correct on every encounter',
       (SELECT count(*)
        FROM star.fact_encounters f
        LEFT JOIN (SELECT encounter_id, sum(allowed_amount) AS s
                   FROM public.billing WHERE claim_status <> 'Denied'
                   GROUP BY 1) src ON src.encounter_id = f.encounter_id
        WHERE f.total_allowed_amount IS DISTINCT FROM COALESCE(src.s, 0)));

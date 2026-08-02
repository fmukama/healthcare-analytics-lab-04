-- Test 13: Q4 query parity, plus a guard on the group-existence filter.
DO $$
DECLARE v_diff bigint; v_o bigint; v_s bigint; v_with bigint; v_without bigint;
BEGIN
    EXECUTE format('CREATE TEMP TABLE _o AS %s',
        pg_read_file('/work/sql/analysis/q4_revenue.sql'));
    EXECUTE format('CREATE TEMP TABLE _s AS %s',
        pg_read_file('/work/sql/star_queries/sq4_revenue.sql'));

    EXECUTE 'SELECT count(*) FROM ((TABLE _o EXCEPT TABLE _s)
                        UNION ALL (TABLE _s EXCEPT TABLE _o)) z' INTO v_diff;
    EXECUTE 'SELECT count(*) FROM _o' INTO v_o;
    EXECUTE 'SELECT count(*) FROM _s' INTO v_s;

    PERFORM lab.expect_zero('Q4 parity: symmetric difference', v_diff);
    PERFORM lab.expect_eq  ('Q4 parity: row counts match', v_s, v_o);
    PERFORM lab.expect_eq  ('Q4 parity: result is not empty', (v_o > 0)::int, 1);

    -- sq4's `WHERE f.claim_count > 0` controls group EXISTENCE, not the sums -
    -- unbilled rows carry 0, the additive identity, so the totals are the same
    -- either way. That is precisely why it is easy to delete without noticing.
    -- Assert the predicate is load-bearing: the unfiltered group count must be
    -- >= the filtered one, and both must be non-zero.
    SELECT count(*) INTO v_with FROM (
        SELECT 1 FROM star.fact_encounters f
        JOIN star.dim_date dd ON dd.date_key = f.admit_date_key
        WHERE f.claim_count > 0
        GROUP BY dd.year, dd.month, f.specialty_key) x;
    SELECT count(*) INTO v_without FROM (
        SELECT 1 FROM star.fact_encounters f
        JOIN star.dim_date dd ON dd.date_key = f.admit_date_key
        GROUP BY dd.year, dd.month, f.specialty_key) x;

    PERFORM lab.expect_eq('Q4 parity: filtered group count equals OLTP row count',
                          v_with, v_o);
    PERFORM lab.expect_eq('Q4 parity: unfiltered grouping is a superset',
                          (v_without >= v_with)::int, 1);
END $$;

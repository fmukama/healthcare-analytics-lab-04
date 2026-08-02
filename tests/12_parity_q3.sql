-- Test 12: Q3 query parity.
-- Slowest file in the suite - it runs the OLTP correlated self-join (~10s), which
-- is exactly the cost the star schema exists to remove. Paying it once in the
-- test suite is the price of proving the fast version is right.
DO $$
DECLARE v_diff bigint; v_o bigint; v_s bigint;
BEGIN
    EXECUTE format('CREATE TEMP TABLE _o AS %s',
        pg_read_file('/work/sql/analysis/q3_readmission.sql'));
    EXECUTE format('CREATE TEMP TABLE _s AS %s',
        pg_read_file('/work/sql/star_queries/sq3_readmission.sql'));

    EXECUTE 'SELECT count(*) FROM ((TABLE _o EXCEPT TABLE _s)
                        UNION ALL (TABLE _s EXCEPT TABLE _o)) z' INTO v_diff;
    EXECUTE 'SELECT count(*) FROM _o' INTO v_o;
    EXECUTE 'SELECT count(*) FROM _s' INTO v_s;

    -- readmission_rate_pct is numeric here. Postgres compares numeric by VALUE,
    -- not display scale, so 34.09 = 34.090 - but the rate expression is still
    -- copied verbatim into sq3, because reassociating it can change the value,
    -- not just the scale.
    PERFORM lab.expect_zero('Q3 parity: symmetric difference', v_diff);
    PERFORM lab.expect_eq  ('Q3 parity: row counts match', v_s, v_o);
    PERFORM lab.expect_eq  ('Q3 parity: result is not empty', (v_o > 0)::int, 1);
END $$;

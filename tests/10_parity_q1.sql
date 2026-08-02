-- Test 10: Q1 query parity.  THE test - fast and wrong is worth nothing.
--
-- Two things about how this is written:
--
-- 1. It reads the ACTUAL shipped .sql files off disk with pg_read_file rather
--    than pasting copies of the queries here. A pasted copy drifts, and then the
--    suite proves parity for SQL that nobody runs. (Requires superuser plus the
--    /work bind mount from docker-compose.yml - both hold here. The fallback if
--    that ever stops being true is to inline both bodies as CTEs.)
--
-- 2. It is a DO block, not a bare SELECT ... EXCEPT. run_tests.sh runs each file
--    with psql -f, and a SELECT that returns rows still exits 0 - only a RAISE
--    fails the run. The wrapper is required, not stylistic.
--
-- Three assertions, each closing a hole the others leave open:
--   symmetric difference  - one-directional EXCEPT passes vacuously if A is empty
--   row counts both sides - EXCEPT is SET semantics and dedupes, so two results
--                           differing only by a duplicate row would slip through
--   non-vacuity           - a broken FROM returning 0 rows on both sides would
--                           otherwise pass everything above
DO $$
DECLARE v_diff bigint; v_o bigint; v_s bigint;
BEGIN
    EXECUTE format('CREATE TEMP TABLE _o AS %s',
        pg_read_file('/work/sql/analysis/q1_monthly_encounters.sql'));
    EXECUTE format('CREATE TEMP TABLE _s AS %s',
        pg_read_file('/work/sql/star_queries/sq1_monthly_encounters.sql'));

    -- A column type mismatch between the two sides raises here rather than
    -- reporting a difference, which is the loud failure we want.
    EXECUTE 'SELECT count(*) FROM ((TABLE _o EXCEPT TABLE _s)
                        UNION ALL (TABLE _s EXCEPT TABLE _o)) z' INTO v_diff;
    EXECUTE 'SELECT count(*) FROM _o' INTO v_o;
    EXECUTE 'SELECT count(*) FROM _s' INTO v_s;

    PERFORM lab.expect_zero('Q1 parity: symmetric difference', v_diff);
    PERFORM lab.expect_eq  ('Q1 parity: row counts match', v_s, v_o);
    PERFORM lab.expect_eq  ('Q1 parity: result is not empty', (v_o > 0)::int, 1);
END $$;

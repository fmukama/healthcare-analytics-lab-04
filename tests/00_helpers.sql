-- =============================================================================
-- Assertion helpers. Loaded by `make test` before the numbered test files run;
-- run_tests.sh explicitly skips this file when globbing for assertions.
--
-- Both raise an exception on failure. With ON_ERROR_STOP=1 that aborts psql
-- with a non-zero exit, which run_tests.sh collects so `make test` and CI go red.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS lab;

-- Two design choices here, each killing a whole class of silent failure:
--
-- 1. NUMERIC parameters, not bigint. smallint/integer/bigint -> numeric are all
--    IMPLICIT casts in Postgres, so one signature transparently accepts
--    count(*) (bigint), sum(smallint) (bigint), sum(numeric) and plain integer
--    literals. A bigint signature would reject the money sums; two overloads
--    would be genuinely ambiguous when called with untyped literals. numeric
--    also compares by VALUE, not display scale, so 139591191.310 = 139591191.31
--    and a scale difference can never produce a false failure.
--
-- 2. IS DISTINCT FROM, not <>. `NULL <> 5` evaluates to NULL, so `IF NULL <> 5
--    THEN RAISE` never fires - an assertion whose query returns NULL (empty
--    SUM, typo'd predicate, mis-joined subquery) would PASS SILENTLY. That is
--    the most common way an assertion suite goes green while proving nothing.
CREATE OR REPLACE FUNCTION lab.expect_eq(p_name TEXT, p_actual NUMERIC, p_expected NUMERIC)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'FAIL  %  expected=%  actual=%', p_name, p_expected, p_actual;
    END IF;
    RAISE NOTICE 'PASS  %  (=%)', p_name, p_actual;
END $$;

CREATE OR REPLACE FUNCTION lab.expect_zero(p_name TEXT, p_actual NUMERIC)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_actual IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL  %  expected 0 offending rows, found %', p_name, p_actual;
    END IF;
    RAISE NOTICE 'PASS  %', p_name;
END $$;

-- The PASS notices matter: run_tests.sh folds stderr into stdout so they land in
-- out/test_results.txt. Without them a passing run produces a blank report and
-- you cannot tell "everything passed" from "nothing ran".

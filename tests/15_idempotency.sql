-- Test 15: idempotency. Re-running the ETL must change nothing.
--
-- This is the one property that CANNOT be a pure SELECT assertion - it requires
-- a second run of a mutating process to observe. So the file wraps a real ETL
-- re-run in a transaction and rolls it back.
--
-- Honest caveats, stated rather than hidden:
--   * this genuinely writes, briefly, and holds locks on the star tables while
--     it runs;
--   * identity sequences are NON-transactional, so nextval values are consumed
--     even though the rows roll back. That is cosmetic: existing surrogate keys
--     do not move, which is the actual property under test.
--
-- The detail that makes or breaks this test: load_ts is EXCLUDED from the
-- checksum. Every dimension upsert sets load_ts = now(), so a naive md5 over
-- whole rows would fail on the second run by design. "Idempotent" means the
-- business data is unchanged, not that the bytes are identical - and knowing the
-- difference is the point.
BEGIN;

CREATE TEMP TABLE _before AS
SELECT
    (SELECT count(*)                    FROM star.fact_encounters)             AS fact_rows,
    (SELECT count(*)                    FROM star.dim_patient)                 AS patients,
    (SELECT count(*)                    FROM star.dim_provider)                AS providers,
    (SELECT count(*)                    FROM star.bridge_encounter_diagnoses)  AS dx_rows,
    (SELECT count(*)                    FROM star.bridge_encounter_procedures) AS px_rows,
    (SELECT sum(total_allowed_amount)   FROM star.fact_encounters)             AS money,
    (SELECT sum(diagnosis_count)        FROM star.fact_encounters)             AS dx_count,
    (SELECT count(*) FILTER (WHERE is_readmit_30d) FROM star.fact_encounters)  AS readmits,
    -- business-column checksum: proves the CONTENT is unchanged, not merely the
    -- row count. Catches the "stale measure" bug that only ever appears on a
    -- second load, which a count-only check would miss entirely.
    (SELECT md5(string_agg(
        encounter_id || '|' || admit_date_key || '|' || patient_key || '|' ||
        specialty_key || '|' || diagnosis_count || '|' || procedure_count || '|' ||
        claim_count || '|' || total_allowed_amount || '|' || is_readmit_30d,
        ',' ORDER BY encounter_id))
     FROM star.fact_encounters)                                                AS fact_md5;

\i /work/sql/etl/01_dims.sql
\i /work/sql/etl/02_fact.sql
\i /work/sql/etl/03_bridges.sql

SELECT lab.expect_eq('idempotent: fact row count unchanged',
       (SELECT count(*) FROM star.fact_encounters), (SELECT fact_rows FROM _before));
SELECT lab.expect_eq('idempotent: dim_patient unchanged',
       (SELECT count(*) FROM star.dim_patient), (SELECT patients FROM _before));
SELECT lab.expect_eq('idempotent: dim_provider unchanged',
       (SELECT count(*) FROM star.dim_provider), (SELECT providers FROM _before));
SELECT lab.expect_eq('idempotent: diagnosis bridge unchanged',
       (SELECT count(*) FROM star.bridge_encounter_diagnoses), (SELECT dx_rows FROM _before));
SELECT lab.expect_eq('idempotent: procedure bridge unchanged',
       (SELECT count(*) FROM star.bridge_encounter_procedures), (SELECT px_rows FROM _before));
SELECT lab.expect_eq('idempotent: revenue unchanged',
       (SELECT sum(total_allowed_amount) FROM star.fact_encounters), (SELECT money FROM _before));
SELECT lab.expect_eq('idempotent: diagnosis_count unchanged',
       (SELECT sum(diagnosis_count) FROM star.fact_encounters), (SELECT dx_count FROM _before));
SELECT lab.expect_eq('idempotent: readmission flags unchanged',
       (SELECT count(*) FILTER (WHERE is_readmit_30d) FROM star.fact_encounters),
       (SELECT readmits FROM _before));

-- The strongest one: every business column on every fact row, byte for byte.
SELECT lab.expect_eq('idempotent: fact content checksum unchanged',
       (SELECT CASE WHEN (SELECT md5(string_agg(
            encounter_id || '|' || admit_date_key || '|' || patient_key || '|' ||
            specialty_key || '|' || diagnosis_count || '|' || procedure_count || '|' ||
            claim_count || '|' || total_allowed_amount || '|' || is_readmit_30d,
            ',' ORDER BY encounter_id)) FROM star.fact_encounters)
                  = (SELECT fact_md5 FROM _before)
               THEN 1 ELSE 0 END), 1);

ROLLBACK;

-- Test 9: dim_date integrity.
-- A missing date row rejects the fact load (NOT NULL FK), so gaps are fatal.

SELECT lab.expect_eq('date: no gaps in the calendar',
       (SELECT count(*) FROM star.dim_date WHERE date_key <> -1),
       (SELECT max(calendar_date) - min(calendar_date) + 1
        FROM star.dim_date WHERE date_key <> -1));

SELECT lab.expect_zero('date: no duplicate calendar_date',
       (SELECT count(*) FROM (
          SELECT calendar_date FROM star.dim_date GROUP BY 1 HAVING count(*) > 1) x));

-- The smart key is only trustworthy if it really is YYYYMMDD - everything
-- downstream (the ETL's to_char(...)::int lookups) assumes it.
SELECT lab.expect_zero('date: date_key really is YYYYMMDD of calendar_date',
       (SELECT count(*) FROM star.dim_date
        WHERE date_key <> -1
          AND date_key IS DISTINCT FROM to_char(calendar_date, 'YYYYMMDD')::int));

-- Coverage. Contiguity alone would not catch "dim_date covers 2023-2027 but
-- someone loaded 2028 data" - that fails at load time, but this says why.
SELECT lab.expect_zero('date: calendar covers every encounter date in use',
       (SELECT count(*) FROM public.encounters e
        WHERE e.encounter_date::date NOT BETWEEN
              (SELECT min(calendar_date) FROM star.dim_date WHERE date_key <> -1)
          AND (SELECT max(calendar_date) FROM star.dim_date WHERE date_key <> -1)));

-- Every date key actually referenced must resolve. The FKs guarantee this for
-- the fact; this covers the bridge's procedure_date_key too.
SELECT lab.expect_zero('date: every referenced date_key exists',
       (SELECT count(*) FROM (
          SELECT admit_date_key AS k FROM star.fact_encounters
          UNION SELECT discharge_date_key FROM star.fact_encounters
          UNION SELECT procedure_date_key FROM star.bridge_encounter_procedures) u
        LEFT JOIN star.dim_date d ON d.date_key = u.k
        WHERE d.date_key IS NULL));

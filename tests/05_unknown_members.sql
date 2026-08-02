-- Test 5: every dimension has exactly one Unknown member.
--
-- Cheap, and it is what proves the "NOT NULL foreign key + -1 Unknown" decision
-- is actually implemented rather than only written down in design_decisions.txt.
-- Without these rows, the ETL's COALESCE(key, -1) would violate a foreign key
-- the first time a lookup failed.

SELECT lab.expect_eq('unknown: dim_date has -1',        (SELECT count(*) FROM star.dim_date           WHERE date_key = -1),           1);
SELECT lab.expect_eq('unknown: dim_patient has -1',     (SELECT count(*) FROM star.dim_patient        WHERE patient_key = -1),        1);
SELECT lab.expect_eq('unknown: dim_provider has -1',    (SELECT count(*) FROM star.dim_provider       WHERE provider_key = -1),       1);
SELECT lab.expect_eq('unknown: dim_specialty has -1',   (SELECT count(*) FROM star.dim_specialty      WHERE specialty_key = -1),      1);
SELECT lab.expect_eq('unknown: dim_department has -1',  (SELECT count(*) FROM star.dim_department     WHERE department_key = -1),     1);
SELECT lab.expect_eq('unknown: dim_encounter_type -1',  (SELECT count(*) FROM star.dim_encounter_type WHERE encounter_type_key = -1), 1);
SELECT lab.expect_eq('unknown: dim_diagnosis has -1',   (SELECT count(*) FROM star.dim_diagnosis      WHERE diagnosis_key = -1),      1);
SELECT lab.expect_eq('unknown: dim_procedure has -1',   (SELECT count(*) FROM star.dim_procedure      WHERE procedure_key = -1),      1);

-- The Unknown date must be a real, sortable date rather than NULL, or reports
-- grouping on it would drop the row they were meant to keep visible.
SELECT lab.expect_eq('unknown: dim_date -1 is 1900-01-01',
       (SELECT count(*) FROM star.dim_date WHERE date_key = -1 AND calendar_date = DATE '1900-01-01'), 1);

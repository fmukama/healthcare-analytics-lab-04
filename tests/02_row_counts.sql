-- Test 2: row-count parity between source and warehouse.
-- Catches silently dropped rows - the INNER JOIN mistake in an ETL.
--
-- Every expectation is a LIVE SUBSELECT, never a hardcoded number. The suite has
-- to pass under `make ci` too (SCALE=ci loads 700 patients / 7,000 encounters),
-- and a hardcoded 70004 would turn the whole suite red on the small dataset.
--
-- Dimensions exclude key = -1 because the Unknown member has no source row.

SELECT lab.expect_eq('rows: fact = public.encounters',
       (SELECT count(*) FROM star.fact_encounters),
       (SELECT count(*) FROM public.encounters));

SELECT lab.expect_eq('rows: dim_patient = public.patients',
       (SELECT count(*) FROM star.dim_patient WHERE patient_key <> -1),
       (SELECT count(*) FROM public.patients));

SELECT lab.expect_eq('rows: dim_provider = public.providers',
       (SELECT count(*) FROM star.dim_provider WHERE provider_key <> -1),
       (SELECT count(*) FROM public.providers));

SELECT lab.expect_eq('rows: dim_specialty = public.specialties',
       (SELECT count(*) FROM star.dim_specialty WHERE specialty_key <> -1),
       (SELECT count(*) FROM public.specialties));

SELECT lab.expect_eq('rows: dim_department = public.departments',
       (SELECT count(*) FROM star.dim_department WHERE department_key <> -1),
       (SELECT count(*) FROM public.departments));

SELECT lab.expect_eq('rows: dim_diagnosis = public.diagnoses',
       (SELECT count(*) FROM star.dim_diagnosis WHERE diagnosis_key <> -1),
       (SELECT count(*) FROM public.diagnoses));

SELECT lab.expect_eq('rows: dim_procedure = public.procedures',
       (SELECT count(*) FROM star.dim_procedure WHERE procedure_key <> -1),
       (SELECT count(*) FROM public.procedures));

-- dim_encounter_type is CURATED, not derived from the facts, so this asserts the
-- curated list covers everything actually present. If the source ever grows a
-- fourth type, this fails - which is the point: reference data should be updated
-- deliberately, not inferred.
SELECT lab.expect_zero('rows: every encounter_type present in dim_encounter_type',
       (SELECT count(*) FROM (
          SELECT DISTINCT encounter_type FROM public.encounters
          EXCEPT SELECT type_name FROM star.dim_encounter_type) x));

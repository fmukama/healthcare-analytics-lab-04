-- Test 11: Q2 parity - the one query whose top-20 is NOT deterministic.
--
-- Q2's ORDER BY has no tiebreaker, and there is a tie AT the LIMIT 20 boundary.
-- On this dataset: the cut value is 140, 13 pairs sit strictly above it, and 8
-- are tied at exactly 140 for the 7 remaining slots. So C(8,7) = 8 different
-- top-20s are all equally correct. Both engines happen to pick the same 7 today,
-- but that is an accident of both plans using a top-N heapsort fed in the same
-- order - change work_mem, add a parallel worker, or let the planner switch to a
-- HashAggregate and the tie-break order moves. Asserting row identity would give
-- a test that goes red on a different machine, which trains people to ignore the
-- suite.
--
-- So this file proves what is actually well defined, and says so out loud in the
-- report. Note it also differs from tests 10/12/13 by inlining the query bodies:
-- the shipped files carry the LIMIT that has to be stripped for a set comparison.
DO $$
DECLARE v_diff bigint; v_o bigint; v_s bigint;
        v_cut_o bigint; v_cut_s bigint; v_above bigint; v_tied bigint;
        v_vec_o bigint[]; v_vec_s bigint[]; v_leak bigint;
BEGIN
    CREATE TEMP TABLE _o AS
        SELECT d.icd10_code, d.icd10_description, pr.cpt_code, pr.cpt_description,
               COUNT(DISTINCT ed.encounter_id) AS encounter_count
        FROM public.encounter_diagnoses ed
        JOIN public.diagnoses d ON d.diagnosis_id = ed.diagnosis_id
        JOIN public.encounter_procedures ep ON ep.encounter_id = ed.encounter_id
        JOIN public.procedures pr ON pr.procedure_id = ep.procedure_id
        GROUP BY 1,2,3,4;

    CREATE TEMP TABLE _s AS
        SELECT dd.icd10_code, dd.icd10_description, dp.cpt_code, dp.cpt_description,
               COUNT(*) AS encounter_count
        FROM star.bridge_encounter_diagnoses bed
        JOIN star.dim_diagnosis dd ON dd.diagnosis_key = bed.diagnosis_key
        JOIN (SELECT DISTINCT encounter_sk, procedure_key
              FROM star.bridge_encounter_procedures) bep
          ON bep.encounter_sk = bed.encounter_sk
        JOIN star.dim_procedure dp ON dp.procedure_key = bep.procedure_key
        GROUP BY 1,2,3,4;

    -- PRIMARY: the full population. Strictly STRONGER than checking 20 rows -
    -- it proves all 2,400 pairs match, so any correct top-20 from either side is
    -- by construction drawn from the same population with the same counts.
    SELECT count(*) INTO v_diff
      FROM ((TABLE _o EXCEPT TABLE _s) UNION ALL (TABLE _s EXCEPT TABLE _o)) z;
    SELECT count(*) INTO v_o FROM _o;
    SELECT count(*) INTO v_s FROM _s;

    PERFORM lab.expect_zero('Q2 parity: FULL result symmetric difference', v_diff);
    PERFORM lab.expect_eq  ('Q2 parity: full row counts match', v_s, v_o);
    PERFORM lab.expect_eq  ('Q2 parity: result is not empty', (v_o > 0)::int, 1);

    -- SECONDARY: what the LIMIT 20 genuinely does guarantee. None of these can
    -- flake, because none of them depend on which tied rows got displayed.
    SELECT min(encounter_count) INTO v_cut_o
      FROM (SELECT encounter_count FROM _o ORDER BY 1 DESC LIMIT 20) x;
    SELECT min(encounter_count) INTO v_cut_s
      FROM (SELECT encounter_count FROM _s ORDER BY 1 DESC LIMIT 20) x;
    PERFORM lab.expect_eq('Q2 parity: top-20 cut value agrees', v_cut_s, v_cut_o);

    SELECT array_agg(encounter_count ORDER BY encounter_count DESC) INTO v_vec_o
      FROM (SELECT encounter_count FROM _o ORDER BY 1 DESC LIMIT 20) x;
    SELECT array_agg(encounter_count ORDER BY encounter_count DESC) INTO v_vec_s
      FROM (SELECT encounter_count FROM _s ORDER BY 1 DESC LIMIT 20) x;
    PERFORM lab.expect_eq('Q2 parity: top-20 count vector identical',
                          (v_vec_o = v_vec_s)::int, 1);

    -- Everything ABOVE the tie is fully deterministic and must match exactly.
    SELECT count(*) INTO v_diff FROM (
        (SELECT * FROM _o WHERE encounter_count > v_cut_o
         EXCEPT SELECT * FROM _s WHERE encounter_count > v_cut_s)
        UNION ALL
        (SELECT * FROM _s WHERE encounter_count > v_cut_s
         EXCEPT SELECT * FROM _o WHERE encounter_count > v_cut_o)) z;
    PERFORM lab.expect_zero('Q2 parity: rows above the cut are identical', v_diff);

    -- Every row either side returns must exist in the other's full result with
    -- the same count - so a displayed row can never be fabricated.
    -- The inner LIMITed selects need their own parentheses: `SELECT ... ORDER BY
    -- ... LIMIT 20 EXCEPT ...` is a syntax error, because ORDER BY/LIMIT bind to
    -- the whole set operation rather than to the left operand.
    SELECT count(*) INTO v_leak FROM (
        ((SELECT * FROM _o ORDER BY encounter_count DESC LIMIT 20) EXCEPT TABLE _s)
        UNION ALL
        ((SELECT * FROM _s ORDER BY encounter_count DESC LIMIT 20) EXCEPT TABLE _o)) z;
    PERFORM lab.expect_zero('Q2 parity: every displayed row exists in both', v_leak);

    -- Non-asserting: puts the tie in out/test_results.txt so the deliverable
    -- SHOWS why row identity is not claimed, instead of quietly omitting it.
    SELECT count(*) INTO v_above FROM _o WHERE encounter_count > v_cut_o;
    SELECT count(*) INTO v_tied  FROM _o WHERE encounter_count = v_cut_o;
    RAISE NOTICE 'INFO  Q2 top-20 is not unique: cut=%, % pairs above it, % tied for the remaining % slots',
                 v_cut_o, v_above, v_tied, 20 - v_above;
END $$;

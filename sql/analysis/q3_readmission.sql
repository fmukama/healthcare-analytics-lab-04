-- Q3: 30-day readmission rate by specialty.
-- Chain: encounters self-joined (via EXISTS) on patient_id, plus providers ->
-- specialties for the index stay.
--
-- Definition: an INDEX STAY is an Inpatient encounter. It is a readmission if
-- the SAME patient has any later encounter starting after discharge_date and
-- within 30 days of it.
--
-- Trap A: a patient can return more than once in 30 days -- a plain JOIN would
-- count that index stay multiple times, pushing the rate over 100%. EXISTS
-- flags each index stay at most once, avoiding that.
-- Trap B: specialty is the INDEX stay's (the care being judged), not the
-- returning visit's.
-- Trap C: strictly `>` discharge_date, not `>=` -- a same-day transfer is not
-- treated as a readmission.
WITH index_stays AS (
    SELECT e.encounter_id, e.patient_id, e.discharge_date, p.specialty_id
    FROM encounters e
    JOIN providers p ON p.provider_id = e.provider_id
    WHERE e.encounter_type = 'Inpatient'
      AND e.discharge_date IS NOT NULL
),
flagged AS (
    SELECT
        i.*,
        EXISTS (
            SELECT 1 FROM encounters e2
            WHERE e2.patient_id = i.patient_id
              AND e2.encounter_id <> i.encounter_id
              AND e2.encounter_date >  i.discharge_date
              AND e2.encounter_date <= i.discharge_date + INTERVAL '30 days'
        ) AS is_readmit
    FROM index_stays i
)
SELECT
    s.specialty_name,
    COUNT(*)                                        AS index_stays,
    SUM(CASE WHEN f.is_readmit THEN 1 ELSE 0 END)   AS readmissions,
    ROUND(100.0 * SUM(CASE WHEN f.is_readmit THEN 1 ELSE 0 END)
                / NULLIF(COUNT(*), 0), 2)            AS readmission_rate_pct
FROM flagged f
JOIN specialties s ON s.specialty_id = f.specialty_id
GROUP BY 1
ORDER BY readmission_rate_pct DESC

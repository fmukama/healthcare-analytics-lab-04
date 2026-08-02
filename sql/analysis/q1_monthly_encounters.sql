-- Q1: Monthly encounters by specialty and encounter type.
-- Joins: encounters -> providers -> specialties   (3 tables, 2 joins)
SELECT
    date_trunc('month', e.encounter_date)::date AS month,
    s.specialty_name,
    e.encounter_type,
    COUNT(*)                        AS total_encounters,
    COUNT(DISTINCT e.patient_id)    AS unique_patients
FROM encounters e
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
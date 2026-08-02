-- =============================================================================
-- dim_date is GENERATED, never extracted from a source table.
-- Cover the data range plus headroom so late-arriving facts always find a date
-- row: 2023-2027 brackets the 2024-2025 encounter window on both sides.
-- A missing date row would reject the fact load (NOT NULL FK) -- which is the
-- correct failure, but an avoidable one.
-- =============================================================================
SET search_path = star, public;

INSERT INTO dim_date (date_key, calendar_date, year, quarter, month, month_name,
                      year_month, day_of_month, day_of_week, day_name,
                      week_of_year, is_weekend)
SELECT to_char(d,'YYYYMMDD')::int, d::date,
       EXTRACT(year FROM d), EXTRACT(quarter FROM d), EXTRACT(month FROM d),
       trim(to_char(d,'Month')), to_char(d,'YYYY-MM'),
       EXTRACT(day FROM d), EXTRACT(isodow FROM d), trim(to_char(d,'Day')),
       EXTRACT(week FROM d), EXTRACT(isodow FROM d) IN (6,7)
FROM generate_series(DATE '2023-01-01', DATE '2027-12-31', INTERVAL '1 day') d
ON CONFLICT (date_key) DO NOTHING;      -- idempotent: safe to re-run

-- The "Unknown" member. Every dimension needs one so facts with unresolvable
-- lookups keep a NOT NULL foreign key instead of a NULL that drops rows.
-- Here it is specifically what lets an encounter with a NULL discharge_date
-- (still admitted) load without inventing a fake discharge date.
INSERT INTO dim_date (date_key, calendar_date, year, quarter, month, month_name,
                      year_month, day_of_month, day_of_week, day_name,
                      week_of_year, is_weekend)
VALUES (-1, DATE '1900-01-01', 1900, 1, 1, 'Unknown', 'Unknown', 1, 1, 'Unknown', 1, FALSE)
ON CONFLICT (date_key) DO NOTHING;

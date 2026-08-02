DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

CREATE TABLE patients (
    patient_id    INT PRIMARY KEY,
    first_name    VARCHAR(100),
    last_name     VARCHAR(100),
    date_of_birth DATE,
    gender        CHAR(1),
    mrn           VARCHAR(20) UNIQUE
);

CREATE TABLE specialties (
    specialty_id   INT PRIMARY KEY,
    specialty_name VARCHAR(100),
    specialty_code VARCHAR(10)
);

CREATE TABLE departments (
    department_id   INT PRIMARY KEY,
    department_name VARCHAR(100),
    floor           INT,          -- "floor" is also a SQL function; fine as a column
    capacity        INT
);

CREATE TABLE providers (
    provider_id   INT PRIMARY KEY,
    first_name    VARCHAR(100),
    last_name     VARCHAR(100),
    credential    VARCHAR(20),
    specialty_id  INT REFERENCES specialties(specialty_id),
    department_id INT REFERENCES departments(department_id)
);

CREATE TABLE encounters (
    encounter_id   INT PRIMARY KEY,
    patient_id     INT REFERENCES patients(patient_id),
    provider_id    INT REFERENCES providers(provider_id),
    encounter_type VARCHAR(50),   -- 'Outpatient' | 'Inpatient' | 'ER'
    encounter_date TIMESTAMP,
    discharge_date TIMESTAMP,
    department_id  INT REFERENCES departments(department_id)
);
CREATE INDEX idx_encounter_date ON encounters (encounter_date);
-- NOTE: no index on patient_id. Foreign keys do NOT create one in Postgres.
-- That is exactly why the Q3 self-join will hurt. Leave it alone for now.

CREATE TABLE diagnoses (
    diagnosis_id      INT PRIMARY KEY,
    icd10_code        VARCHAR(10),
    icd10_description VARCHAR(200)
);

CREATE TABLE encounter_diagnoses (
    encounter_diagnosis_id INT PRIMARY KEY,
    encounter_id           INT REFERENCES encounters(encounter_id),
    diagnosis_id           INT REFERENCES diagnoses(diagnosis_id),
    diagnosis_sequence     INT            -- 1 = primary diagnosis
);

CREATE TABLE procedures (
    procedure_id    INT PRIMARY KEY,
    cpt_code        VARCHAR(10),
    cpt_description VARCHAR(200)
);

CREATE TABLE encounter_procedures (
    encounter_procedure_id INT PRIMARY KEY,
    encounter_id           INT REFERENCES encounters(encounter_id),
    procedure_id           INT REFERENCES procedures(procedure_id),
    procedure_date         DATE
);

CREATE TABLE billing (
    billing_id     INT PRIMARY KEY,
    encounter_id   INT REFERENCES encounters(encounter_id),
    claim_amount   DECIMAL(12,2),   -- what the hospital billed
    allowed_amount DECIMAL(12,2),   -- what the insurer agreed to pay  <-- use this
    claim_date     DATE,
    claim_status   VARCHAR(50)      -- 'Paid' | 'Pending' | 'Denied'
);
CREATE INDEX idx_claim_date ON billing (claim_date);
-- =============================================================================
-- 05_masking.sql
-- Tag-based masking: personal data is masked for everyone except approved roles.
--
-- The policies are attached to the pii_type TAG, not to columns. Every column
-- tagged in 04 is protected automatically, and so is any column tagged later.
-- Protection follows classification: nobody has to remember to attach a policy.
--
-- Who may see real values is not written in the policy itself, but in a lookup
-- table (governance.pii_access). Adding or removing a role is a row change that
-- an auditor can read, not a code change.
--
-- The policies check CURRENT_ROLE(), the primary role only. Snowflake users can
-- also have secondary roles active; checking only the primary role means a
-- secondary role can never widen access to personal data.
--
-- Run as: GOVERNANCE_ADMIN (and SECURITYADMIN for one grant). Rerunnable.
-- =============================================================================

USE ROLE governance_admin;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.governance;


-- -----------------------------------------------------------------------------
-- 1. Who may see unmasked personal data, and why
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pii_access (
    role_name    STRING NOT NULL,
    reason       STRING NOT NULL,
    approved_by  STRING NOT NULL
)
COMMENT = 'Roles allowed to see unmasked personal data. Read by the masking policies.';

INSERT OVERWRITE INTO pii_access VALUES
    ('FR_PRIVACY_OFFICER', 'Handles data subject requests and must identify the customer', 'Data Protection Officer'),
    ('SYSADMIN',           'Pipeline role: copies real values from raw into the vault',    'Head of Data Platform');


-- -----------------------------------------------------------------------------
-- 2. Masking policies, one per data type
-- NULL stays NULL, so completeness checks (07) give the same answer for every role.
-- Emails keep the domain, IBANs keep the country: still useful for analysis,
-- no longer identifying.
-- -----------------------------------------------------------------------------
CREATE MASKING POLICY IF NOT EXISTS mask_pii_string AS (val STRING) RETURNS STRING ->
    CASE
        WHEN val IS NULL THEN NULL
        WHEN EXISTS (SELECT 1 FROM neobank.governance.pii_access a WHERE a.role_name = CURRENT_ROLE())
            THEN val
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('neobank.governance.pii_type') = 'EMAIL'
            THEN REGEXP_REPLACE(val, '^[^@]+', '*****')
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('neobank.governance.pii_type') = 'IBAN'
            THEN LEFT(val, 2) || REPEAT('*', LENGTH(val) - 2)
        ELSE '*****'
    END
    COMMENT = 'Masks personal data in text columns tagged with pii_type';

-- Dates of birth: unapproved roles see 1 January of the birth year.
CREATE MASKING POLICY IF NOT EXISTS mask_pii_date AS (val DATE) RETURNS DATE ->
    CASE
        WHEN val IS NULL THEN NULL
        WHEN EXISTS (SELECT 1 FROM neobank.governance.pii_access a WHERE a.role_name = CURRENT_ROLE())
            THEN val
        ELSE DATE_FROM_PARTS(YEAR(val), 1, 1)
    END
    COMMENT = 'Generalises dates tagged with pii_type to the year';


-- -----------------------------------------------------------------------------
-- 3. Attach the policies to the tag
-- FORCE replaces a policy that is already attached, so the script can be rerun.
-- -----------------------------------------------------------------------------
ALTER TAG pii_type SET
    MASKING POLICY mask_pii_string,
    MASKING POLICY mask_pii_date
    FORCE;


-- Auditors may read who has PII access (managed-access schema: SECURITYADMIN grants).
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE neobank.governance.pii_access TO ROLE ar_governance_read;


-- -----------------------------------------------------------------------------
-- 4. Test: same table, different roles
-- USE SECONDARY ROLES NONE so the test shows exactly one role's view.
-- -----------------------------------------------------------------------------
USE SECONDARY ROLES NONE;

-- Data engineer: can read raw, but personal data is masked.
-- Expected: ***** names, *****@example.com, birth date on 1 January, DE00******.
USE ROLE fr_data_engineer;
SELECT c.first_name, c.last_name, c.email, c.date_of_birth, c.tax_id, a.iban
FROM neobank.raw.customers c
JOIN neobank.raw.accounts a ON a.customer_id = c.customer_id
LIMIT 5;

-- Privacy officer: sees the real values in the vault.
USE ROLE fr_privacy_officer;
SELECT customer_token, first_name, last_name, email, date_of_birth, tax_id
FROM neobank.governance.customer_identity
LIMIT 5;

USE SECONDARY ROLES ALL;

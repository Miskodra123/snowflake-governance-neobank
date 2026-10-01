-- =============================================================================
-- 06_row_access.sql
-- Row access: analysts see only the rows of the legal entity they work for.
--
-- The neobank has two legal entities: NEOBANK_DE (German customers) and
-- NEOBANK_EU (branches in France, Spain, Italy and the Netherlands). A German
-- analyst should not see EU branch customers, and the other way round.
--
-- Masking (05) hides columns. A row access policy hides rows. Both are
-- invisible to the user: the query is the same, the result depends on the role.
--
-- As in 05, entitlements live in a lookup table and the policy checks the
-- primary role only.
--
-- Run as: GOVERNANCE_ADMIN. Rerunnable.
-- =============================================================================

USE ROLE governance_admin;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.governance;


-- -----------------------------------------------------------------------------
-- 1. Entitlements: which role may see which legal entity
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS legal_entity_access (
    role_name     STRING NOT NULL,
    legal_entity  STRING NOT NULL,
    reason        STRING NOT NULL
)
COMMENT = 'Which role may see rows of which legal entity. Read by rap_legal_entity.';

INSERT OVERWRITE INTO legal_entity_access VALUES
    ('FR_ANALYST_DE',      'NEOBANK_DE', 'Analyst for the German entity'),
    ('FR_ANALYST_EU',      'NEOBANK_EU', 'Analyst for the EU branches'),
    ('FR_DATA_ENGINEER',   'NEOBANK_DE', 'Pipeline support across entities'),
    ('FR_DATA_ENGINEER',   'NEOBANK_EU', 'Pipeline support across entities'),
    ('FR_PRIVACY_OFFICER', 'NEOBANK_DE', 'Data subject requests for all customers'),
    ('FR_PRIVACY_OFFICER', 'NEOBANK_EU', 'Data subject requests for all customers'),
    ('SYSADMIN',           'NEOBANK_DE', 'Pipeline and erasure procedure'),
    ('SYSADMIN',           'NEOBANK_EU', 'Pipeline and erasure procedure');


-- -----------------------------------------------------------------------------
-- 2. Policy: a row is visible if the current role is entitled to its entity
-- -----------------------------------------------------------------------------
CREATE ROW ACCESS POLICY IF NOT EXISTS rap_legal_entity AS (entity STRING) RETURNS BOOLEAN ->
    EXISTS (
        SELECT 1
        FROM neobank.governance.legal_entity_access a
        WHERE a.role_name = CURRENT_ROLE()
          AND a.legal_entity = entity
    )
    COMMENT = 'Rows visible only to roles entitled to the row''s legal entity';


-- -----------------------------------------------------------------------------
-- 3. Attach to every core table that has a legal_entity column
-- DROP ALL first, so the script can be rerun (a table holds one row access policy).
-- -----------------------------------------------------------------------------
ALTER TABLE neobank.core.customers    DROP ALL ROW ACCESS POLICIES;
ALTER TABLE neobank.core.customers    ADD ROW ACCESS POLICY rap_legal_entity ON (legal_entity);

ALTER TABLE neobank.core.accounts     DROP ALL ROW ACCESS POLICIES;
ALTER TABLE neobank.core.accounts     ADD ROW ACCESS POLICY rap_legal_entity ON (legal_entity);

ALTER TABLE neobank.core.transactions DROP ALL ROW ACCESS POLICIES;
ALTER TABLE neobank.core.transactions ADD ROW ACCESS POLICY rap_legal_entity ON (legal_entity);

USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE neobank.governance.legal_entity_access TO ROLE ar_governance_read;


-- -----------------------------------------------------------------------------
-- 4. Test: the same query under three roles
-- Expected: DE analyst sees only NEOBANK_DE, EU analyst only NEOBANK_EU,
-- data engineer both. Totals add up to 10,000.
-- -----------------------------------------------------------------------------
USE SECONDARY ROLES NONE;

USE ROLE fr_analyst_de;
SELECT 'FR_ANALYST_DE' AS role, legal_entity, COUNT(*) AS customers
FROM neobank.core.customers GROUP BY legal_entity;

USE ROLE fr_analyst_eu;
SELECT 'FR_ANALYST_EU' AS role, legal_entity, COUNT(*) AS customers
FROM neobank.core.customers GROUP BY legal_entity;

USE ROLE fr_data_engineer;
SELECT 'FR_DATA_ENGINEER' AS role, legal_entity, COUNT(*) AS customers
FROM neobank.core.customers GROUP BY legal_entity;

USE SECONDARY ROLES ALL;

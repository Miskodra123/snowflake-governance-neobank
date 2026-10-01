-- =============================================================================
-- 03_roles.sql
-- Role hierarchy: access roles hold privileges, functional roles are jobs.
--
--   Access roles (AR_*)     one technical permission set each, e.g. "read core".
--                           Never granted to people directly.
--   Functional roles (FR_*) one per job. Built by combining access roles.
--                           Granted to people.
--
-- Why two layers: when a job changes, you change which access roles it holds,
-- not dozens of object grants. And an auditor can read "who can do what" from a
-- short list of access roles.
--
-- Separation of duties:
--   SYSADMIN          owns the data objects and runs the pipeline
--   GOVERNANCE_ADMIN  owns tags and policies, but cannot read customer data
--   SECURITYADMIN     manages grants (it has MANAGE GRANTS, needed for the
--                     managed-access schemas)
--
-- Run as: USERADMIN, SECURITYADMIN and ACCOUNTADMIN (switched inside the script).
-- Rerunnable.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Create roles (USERADMIN creates roles and users, nothing else)
-- -----------------------------------------------------------------------------
USE ROLE USERADMIN;

-- Access roles
CREATE ROLE IF NOT EXISTS ar_wh_usage        COMMENT = 'Access role: use the neobank warehouse';
CREATE ROLE IF NOT EXISTS ar_raw_read        COMMENT = 'Access role: read RAW (contains direct identifiers, masked by policy)';
CREATE ROLE IF NOT EXISTS ar_core_read       COMMENT = 'Access role: read CORE (pseudonymised)';
CREATE ROLE IF NOT EXISTS ar_vault_read      COMMENT = 'Access role: read the identity vault';
CREATE ROLE IF NOT EXISTS ar_governance_read COMMENT = 'Access role: read governance tables except the vault';

-- Functional roles
CREATE ROLE IF NOT EXISTS fr_analyst_de      COMMENT = 'Functional role: analyst for the German entity';
CREATE ROLE IF NOT EXISTS fr_analyst_eu      COMMENT = 'Functional role: analyst for the EU branches';
CREATE ROLE IF NOT EXISTS fr_data_engineer   COMMENT = 'Functional role: builds and fixes pipelines';
CREATE ROLE IF NOT EXISTS fr_privacy_officer COMMENT = 'Functional role: data protection, handles erasure requests';
CREATE ROLE IF NOT EXISTS fr_auditor         COMMENT = 'Functional role: internal audit, read-only evidence';
CREATE ROLE IF NOT EXISTS governance_admin   COMMENT = 'Owns tags and policies. Cannot read customer data.';


-- -----------------------------------------------------------------------------
-- 2. Privileges on access roles (SECURITYADMIN)
-- -----------------------------------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT USAGE ON WAREHOUSE neobank_wh TO ROLE ar_wh_usage;

GRANT USAGE ON DATABASE neobank                       TO ROLE ar_raw_read;
GRANT USAGE ON SCHEMA neobank.raw                     TO ROLE ar_raw_read;
GRANT SELECT ON ALL TABLES IN SCHEMA neobank.raw      TO ROLE ar_raw_read;
GRANT SELECT ON FUTURE TABLES IN SCHEMA neobank.raw   TO ROLE ar_raw_read;

GRANT USAGE ON DATABASE neobank                       TO ROLE ar_core_read;
GRANT USAGE ON SCHEMA neobank.core                    TO ROLE ar_core_read;
GRANT SELECT ON ALL TABLES IN SCHEMA neobank.core     TO ROLE ar_core_read;
GRANT SELECT ON FUTURE TABLES IN SCHEMA neobank.core  TO ROLE ar_core_read;

-- Vault and governance tables: explicit grants per table, no FUTURE grants.
-- A future grant on the governance schema would also cover the vault.
GRANT USAGE ON DATABASE neobank                           TO ROLE ar_vault_read;
GRANT USAGE ON SCHEMA neobank.governance                  TO ROLE ar_vault_read;
GRANT SELECT ON TABLE neobank.governance.customer_identity TO ROLE ar_vault_read;

GRANT USAGE ON DATABASE neobank                       TO ROLE ar_governance_read;
GRANT USAGE ON SCHEMA neobank.governance              TO ROLE ar_governance_read;
GRANT SELECT ON TABLE neobank.governance.erasure_log  TO ROLE ar_governance_read;

-- Governance admin: may create tags, policies and policy lookup tables in the
-- governance schema. Gets no SELECT on customer data.
GRANT USAGE ON DATABASE neobank                       TO ROLE governance_admin;
GRANT USAGE ON SCHEMA neobank.raw                     TO ROLE governance_admin;
GRANT USAGE ON SCHEMA neobank.core                    TO ROLE governance_admin;
GRANT USAGE ON SCHEMA neobank.governance              TO ROLE governance_admin;
GRANT CREATE TAG                ON SCHEMA neobank.governance TO ROLE governance_admin;
GRANT CREATE MASKING POLICY     ON SCHEMA neobank.governance TO ROLE governance_admin;
GRANT CREATE ROW ACCESS POLICY  ON SCHEMA neobank.governance TO ROLE governance_admin;
GRANT CREATE TABLE              ON SCHEMA neobank.governance TO ROLE governance_admin;


-- -----------------------------------------------------------------------------
-- 3. Functional roles = combinations of access roles
-- -----------------------------------------------------------------------------
GRANT ROLE ar_wh_usage        TO ROLE fr_analyst_de;
GRANT ROLE ar_core_read       TO ROLE fr_analyst_de;

GRANT ROLE ar_wh_usage        TO ROLE fr_analyst_eu;
GRANT ROLE ar_core_read       TO ROLE fr_analyst_eu;

GRANT ROLE ar_wh_usage        TO ROLE fr_data_engineer;
GRANT ROLE ar_raw_read        TO ROLE fr_data_engineer;
GRANT ROLE ar_core_read       TO ROLE fr_data_engineer;

GRANT ROLE ar_wh_usage        TO ROLE fr_privacy_officer;
GRANT ROLE ar_core_read       TO ROLE fr_privacy_officer;
GRANT ROLE ar_vault_read      TO ROLE fr_privacy_officer;
GRANT ROLE ar_governance_read TO ROLE fr_privacy_officer;

GRANT ROLE ar_wh_usage        TO ROLE fr_auditor;
GRANT ROLE ar_governance_read TO ROLE fr_auditor;

GRANT ROLE ar_wh_usage        TO ROLE governance_admin;
GRANT ROLE ar_governance_read TO ROLE governance_admin;

-- Hierarchy. Business roles roll up to SYSADMIN, as Snowflake recommends.
-- Privacy, audit and governance roles roll up to SECURITYADMIN instead, so the
-- data platform team (SYSADMIN) does not inherit them.
GRANT ROLE fr_analyst_de      TO ROLE SYSADMIN;
GRANT ROLE fr_analyst_eu      TO ROLE SYSADMIN;
GRANT ROLE fr_data_engineer   TO ROLE SYSADMIN;
GRANT ROLE fr_privacy_officer TO ROLE SECURITYADMIN;
GRANT ROLE fr_auditor         TO ROLE SECURITYADMIN;
GRANT ROLE governance_admin   TO ROLE SECURITYADMIN;


-- -----------------------------------------------------------------------------
-- 4. Account-level privileges (only ACCOUNTADMIN can grant these)
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- Governance admin applies tags and policies to tables it does not own.
-- This is what makes policy management central: table owners cannot remove
-- a policy, and the governance team does not need to own the data.
GRANT APPLY TAG                ON ACCOUNT TO ROLE governance_admin;
GRANT APPLY MASKING POLICY     ON ACCOUNT TO ROLE governance_admin;
GRANT APPLY ROW ACCESS POLICY  ON ACCOUNT TO ROLE governance_admin;

-- Read-only access to Snowflake's governance views (access history, policy and
-- tag references, grants). GOVERNANCE_VIEWER is narrower than all of ACCOUNT_USAGE.
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE fr_auditor;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE governance_admin;

-- Data quality (07): SYSADMIN owns the tables, so it attaches the data metric
-- functions. Auditors can read the results.
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE SYSADMIN;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE SYSADMIN;
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE SYSADMIN;
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE fr_auditor;


-- -----------------------------------------------------------------------------
-- 5. Give the demo user every functional role, to test each view in 05-09
-- -----------------------------------------------------------------------------
USE ROLE SECURITYADMIN;
-- Quoted, because user names created at sign-up can contain characters such as
-- '@' or '.' that are not valid in an unquoted identifier.
SET my_user = '"' || CURRENT_USER() || '"';

GRANT ROLE fr_analyst_de      TO USER IDENTIFIER($my_user);
GRANT ROLE fr_analyst_eu      TO USER IDENTIFIER($my_user);
GRANT ROLE fr_data_engineer   TO USER IDENTIFIER($my_user);
GRANT ROLE fr_privacy_officer TO USER IDENTIFIER($my_user);
GRANT ROLE fr_auditor         TO USER IDENTIFIER($my_user);
GRANT ROLE governance_admin   TO USER IDENTIFIER($my_user);


-- -----------------------------------------------------------------------------
-- 6. Check the result: which access roles each functional role holds
-- -----------------------------------------------------------------------------
SHOW ROLES LIKE 'FR_%';
SHOW GRANTS TO ROLE fr_privacy_officer;

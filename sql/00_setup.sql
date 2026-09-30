-- =============================================================================
-- 00_setup.sql
-- Warehouse, cost guardrail, database and the three zones (schemas).
--
-- Run as: ACCOUNTADMIN for the resource monitor (step 1), SYSADMIN for the rest.
-- Safe to rerun: every statement uses IF NOT EXISTS, so nothing is dropped.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Cost guardrail
-- A resource monitor caps how many credits the warehouse can use per month.
-- At 80% it sends a notification, at 100% it suspends the warehouse.
-- Only ACCOUNTADMIN can create resource monitors.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS neobank_monitor
    WITH CREDIT_QUOTA = 20
         FREQUENCY = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
         TRIGGERS ON 80 PERCENT DO NOTIFY
                  ON 100 PERCENT DO SUSPEND;


-- -----------------------------------------------------------------------------
-- 2. Warehouse (compute)
-- XSMALL is the smallest size (1 credit per hour while running).
-- AUTO_SUSPEND = 60: stops after 60 seconds idle, so we only pay while queries run.
-- Created by SYSADMIN, not ACCOUNTADMIN: day-to-day objects should not be owned
-- by the most powerful role.
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS neobank_wh
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for the neobank governance project';

USE ROLE ACCOUNTADMIN;
ALTER WAREHOUSE neobank_wh SET RESOURCE_MONITOR = neobank_monitor;

USE ROLE SYSADMIN;
USE WAREHOUSE neobank_wh;


-- -----------------------------------------------------------------------------
-- 3. Database
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS neobank
    COMMENT = 'Fictional neobank: governance as code demo. Synthetic data only.';

USE DATABASE neobank;


-- -----------------------------------------------------------------------------
-- 4. Zones (schemas). Retention is chosen per zone, on purpose.
--
-- Two Snowflake terms:
--   Time Travel = how many days you can still query or restore deleted data.
--                 Set with DATA_RETENTION_TIME_IN_DAYS.
--   Fail-safe   = 7 more days after Time Travel, recoverable only by Snowflake
--                 support. Permanent tables have it, transient tables do not.
-- Both matter for the right to be forgotten: deleted personal data still exists
-- until Time Travel and Fail-safe have both run out.
-- -----------------------------------------------------------------------------

-- raw: data as it lands.
-- TRANSIENT = no Fail-safe, and Time Travel of 1 day (the maximum for transient).
-- So personal data deleted here is gone after 1 day, not 1 + 7 days.
-- Trade-off: raw cannot be recovered by Snowflake support. Acceptable, because
-- raw can be reloaded from the source system.
CREATE TRANSIENT SCHEMA IF NOT EXISTS raw
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'Landing zone. Transient: no Fail-safe, 1 day Time Travel.';

-- core: cleaned, pseudonymised tables for analysts.
-- MANAGED ACCESS = only the schema owner (or a role with MANAGE GRANTS) can grant
-- access to tables here. Without it, whoever creates a table can share it with
-- anyone. This keeps access control in one place.
-- 7 days Time Travel: room to recover from a bad load or a mistaken delete.
CREATE SCHEMA IF NOT EXISTS core
    WITH MANAGED ACCESS
    DATA_RETENTION_TIME_IN_DAYS = 7
    COMMENT = 'Pseudonymised analytical tables. Managed access.';

-- governance: mapping table (token to real identity), tags, policies, CDE register.
-- The most sensitive zone. Managed access, and only 1 day Time Travel, so an
-- erased customer's mapping row stops being restorable after 1 day.
-- Permanent (not transient) because losing the mapping table would make all
-- pseudonymised data unusable. Its 7 days of Fail-safe are only reachable by
-- Snowflake support, and they expire well inside GDPR's one-month deadline.
CREATE SCHEMA IF NOT EXISTS governance
    WITH MANAGED ACCESS
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'Mapping table, tags, policies, CDE register. Managed access.';


-- -----------------------------------------------------------------------------
-- 5. Check the result
-- Look at the "options" column (TRANSIENT, MANAGED ACCESS) and "retention_time".
-- -----------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE neobank;
SHOW WAREHOUSES LIKE 'NEOBANK_WH';

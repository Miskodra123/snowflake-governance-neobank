-- =============================================================================
-- 07_data_quality.sql
-- Quality controls on Critical Data Elements (CDEs), with stored evidence.
--
--   governance.dq_rules      one row per check: which CDE, which metric, which
--                            threshold, who owns it. Same rules as
--                            governance/cde_register.yml.
--   governance.run_dq_checks measures every rule and appends PASS/FAIL to
--                            governance.dq_results (the audit evidence)
--   daily task               runs the checks every morning
--   data metric functions    Snowflake's native monitoring, attached to the
--                            tables on the same daily schedule
--
-- Two Snowflake limits found while building this, worth knowing:
--   - SNOWFLAKE.CORE.FRESHNESS only accepts TIMESTAMP_LTZ / TIMESTAMP_TZ columns,
--     and custom data metric functions may not call CURRENT_TIMESTAMP. Freshness
--     is therefore checked in plain SQL inside the procedure.
--   - The seeded defects from 01 are expected to FAIL: 293 negative amounts and
--     1.05% missing emails. A check that never fails proves nothing.
--
-- Run as: SYSADMIN (owns the tables), ACCOUNTADMIN and SECURITYADMIN for grants.
-- Rerunnable.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.governance;


-- -----------------------------------------------------------------------------
-- 1. Custom data metric functions (Snowflake ships NULL_COUNT, DUPLICATE_COUNT etc.)
-- -----------------------------------------------------------------------------
CREATE DATA METRIC FUNCTION IF NOT EXISTS dmf_negative_amount_count(t TABLE(amount NUMBER))
    RETURNS NUMBER
    COMMENT = 'Number of transactions with a negative amount. Amounts must be positive, direction says debit or credit.'
    AS 'SELECT COUNT_IF(amount < 0) FROM t';

CREATE DATA METRIC FUNCTION IF NOT EXISTS dmf_invalid_kyc_status_count(t TABLE(kyc_status STRING))
    RETURNS NUMBER
    COMMENT = 'Number of customers whose KYC status is missing or not an allowed value.'
    AS $$
        SELECT COUNT_IF(kyc_status IS NULL OR kyc_status NOT IN ('VERIFIED', 'PENDING', 'REJECTED')) FROM t
    $$;


-- -----------------------------------------------------------------------------
-- 2. Rules: what "good" means for each CDE
-- Dimensions follow the usual data quality model (and BCBS 239 principles 3-5):
-- completeness, validity, uniqueness, consistency, timeliness.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_rules (
    rule_id        STRING NOT NULL,
    cde            STRING NOT NULL COMMENT 'Critical Data Element, as named in cde_register.yml',
    target         STRING NOT NULL COMMENT 'table.column checked',
    dimension      STRING NOT NULL,
    check_desc     STRING NOT NULL,
    threshold_max  NUMBER(12, 2) NOT NULL COMMENT 'Check passes if the measured value is at or below this',
    owner          STRING NOT NULL,
    CONSTRAINT pk_dq_rules PRIMARY KEY (rule_id)
)
COMMENT = 'Data quality rules for Critical Data Elements. Mirrors governance/cde_register.yml.';

INSERT OVERWRITE INTO dq_rules VALUES
    ('DQ01', 'Transaction amount',   'core.transactions.amount',       'Completeness', 'No missing amounts',                         0,    'Head of Payments'),
    ('DQ02', 'Transaction amount',   'core.transactions.amount',       'Validity',     'No negative amounts',                        0,    'Head of Payments'),
    ('DQ03', 'Booking date',         'core.transactions.booked_at',    'Completeness', 'No missing booking dates',                   0,    'Head of Payments'),
    ('DQ04', 'Transactions',         'core.transactions._loaded_at',   'Timeliness',   'Loaded within the last 24 hours (SLA)',      24,   'Head of Payments'),
    ('DQ05', 'Transactions',         'core.transactions.account_id',   'Consistency',  'Every transaction belongs to a known account', 0,  'Head of Payments'),
    ('DQ06', 'Account status',       'core.accounts.status',           'Completeness', 'No missing account status',                  0,    'Head of Retail Banking'),
    ('DQ07', 'Account ID',           'core.accounts.account_id',       'Uniqueness',   'No duplicate account IDs',                   0,    'Head of Retail Banking'),
    ('DQ08', 'Customer token',       'core.customers.customer_token',  'Uniqueness',   'No duplicate customer tokens',               0,    'Head of Customer Onboarding'),
    ('DQ09', 'Customer legal entity','core.customers.legal_entity',    'Completeness', 'No missing legal entity',                    0,    'Head of Customer Onboarding'),
    ('DQ10', 'KYC status',           'core.customers.kyc_status',      'Validity',     'Only allowed KYC status values',             0,    'Head of Customer Onboarding'),
    ('DQ11', 'Customer email',       'governance.customer_identity.email', 'Completeness', 'At most 0.5% of customers without email', 0.5, 'Data Protection Officer');


-- -----------------------------------------------------------------------------
-- 3. Results log: one row per rule per run. This is the evidence an auditor reads.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_results (
    run_at          TIMESTAMP_NTZ NOT NULL,
    rule_id         STRING        NOT NULL,
    measured_value  NUMBER(18, 2),
    threshold_max   NUMBER(12, 2),
    status          STRING        COMMENT 'PASS or FAIL'
)
COMMENT = 'History of data quality check results. Append-only.';


-- -----------------------------------------------------------------------------
-- 4. Procedure: measure every rule, compare with its threshold, log the result
-- Runs with the owner's rights (SYSADMIN), so it sees all rows regardless of
-- who calls it. Anyone with the auditor role can read the results, not the data.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE run_dq_checks()
    RETURNS STRING
    LANGUAGE SQL
    COMMENT = 'Measures all rules in dq_rules and appends the results to dq_results'
    EXECUTE AS OWNER
AS
$$
BEGIN
    INSERT INTO neobank.governance.dq_results (run_at, rule_id, measured_value, threshold_max, status)
    SELECT
        CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
        r.rule_id,
        m.measured_value,
        r.threshold_max,
        IFF(m.measured_value <= r.threshold_max, 'PASS', 'FAIL')
    FROM neobank.governance.dq_rules r
    JOIN (
        SELECT 'DQ01' AS rule_id, SNOWFLAKE.CORE.NULL_COUNT(SELECT amount FROM neobank.core.transactions) AS measured_value
        UNION ALL SELECT 'DQ02', neobank.governance.dmf_negative_amount_count(SELECT amount FROM neobank.core.transactions)
        UNION ALL SELECT 'DQ03', SNOWFLAKE.CORE.NULL_COUNT(SELECT booked_at FROM neobank.core.transactions)
        UNION ALL SELECT 'DQ04', DATEDIFF(hour, MAX(_loaded_at), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) FROM neobank.core.transactions
        UNION ALL SELECT 'DQ05', COUNT(*) FROM neobank.core.transactions t
                  WHERE NOT EXISTS (SELECT 1 FROM neobank.core.accounts a WHERE a.account_id = t.account_id)
        UNION ALL SELECT 'DQ06', SNOWFLAKE.CORE.NULL_COUNT(SELECT status FROM neobank.core.accounts)
        UNION ALL SELECT 'DQ07', SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT account_id FROM neobank.core.accounts)
        UNION ALL SELECT 'DQ08', SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT customer_token FROM neobank.core.customers)
        UNION ALL SELECT 'DQ09', SNOWFLAKE.CORE.NULL_COUNT(SELECT legal_entity FROM neobank.core.customers)
        UNION ALL SELECT 'DQ10', neobank.governance.dmf_invalid_kyc_status_count(SELECT kyc_status FROM neobank.core.customers)
        UNION ALL SELECT 'DQ11', SNOWFLAKE.CORE.NULL_PERCENT(SELECT email FROM neobank.governance.customer_identity)
    ) m
      ON m.rule_id = r.rule_id;
    RETURN 'Data quality checks logged: ' || SQLROWCOUNT;
END;
$$;


-- -----------------------------------------------------------------------------
-- 5. Run the checks every day at 06:00 UTC
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;
CREATE OR REPLACE TASK daily_dq_checks
    WAREHOUSE = neobank_wh
    SCHEDULE  = 'USING CRON 0 6 * * * UTC'
    COMMENT   = 'Daily data quality checks on Critical Data Elements'
AS
    CALL neobank.governance.run_dq_checks();

ALTER TASK daily_dq_checks RESUME;


-- -----------------------------------------------------------------------------
-- 6. Native monitoring: attach data metric functions to the tables
-- Results land in SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS.
-- Attaching the same function twice fails, so each table is wrapped in a block
-- that reports "already attached" on a rerun instead of stopping the script.
-- -----------------------------------------------------------------------------
ALTER TABLE neobank.core.transactions           SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * * UTC';
ALTER TABLE neobank.core.accounts               SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * * UTC';
ALTER TABLE neobank.core.customers              SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * * UTC';
ALTER TABLE neobank.governance.customer_identity SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * * UTC';

EXECUTE IMMEDIATE $$
BEGIN
    ALTER TABLE neobank.core.transactions ADD DATA METRIC FUNCTION
        SNOWFLAKE.CORE.NULL_COUNT ON (amount),
        neobank.governance.dmf_negative_amount_count ON (amount),
        SNOWFLAKE.CORE.NULL_COUNT ON (booked_at);
    RETURN 'transactions: attached';
EXCEPTION
    WHEN OTHER THEN RETURN 'transactions: ' || SQLERRM;
END;
$$;

EXECUTE IMMEDIATE $$
BEGIN
    ALTER TABLE neobank.core.accounts ADD DATA METRIC FUNCTION
        SNOWFLAKE.CORE.NULL_COUNT ON (status),
        SNOWFLAKE.CORE.DUPLICATE_COUNT ON (account_id);
    RETURN 'accounts: attached';
EXCEPTION
    WHEN OTHER THEN RETURN 'accounts: ' || SQLERRM;
END;
$$;

EXECUTE IMMEDIATE $$
BEGIN
    ALTER TABLE neobank.core.customers ADD DATA METRIC FUNCTION
        SNOWFLAKE.CORE.DUPLICATE_COUNT ON (customer_token),
        SNOWFLAKE.CORE.NULL_COUNT ON (legal_entity),
        neobank.governance.dmf_invalid_kyc_status_count ON (kyc_status);
    RETURN 'customers: attached';
EXCEPTION
    WHEN OTHER THEN RETURN 'customers: ' || SQLERRM;
END;
$$;

EXECUTE IMMEDIATE $$
BEGIN
    ALTER TABLE neobank.governance.customer_identity ADD DATA METRIC FUNCTION
        SNOWFLAKE.CORE.NULL_PERCENT ON (email);
    RETURN 'customer_identity: attached';
EXCEPTION
    WHEN OTHER THEN RETURN 'customer_identity: ' || SQLERRM;
END;
$$;


-- -----------------------------------------------------------------------------
-- 7. Auditors may read rules and results (managed-access schema: SECURITYADMIN)
-- -----------------------------------------------------------------------------
USE ROLE SECURITYADMIN;
GRANT SELECT ON TABLE neobank.governance.dq_rules   TO ROLE ar_governance_read;
GRANT SELECT ON TABLE neobank.governance.dq_results TO ROLE ar_governance_read;


-- -----------------------------------------------------------------------------
-- 8. Run once now and show the scorecard
-- Expected: DQ02 FAIL (293 negative amounts), DQ11 FAIL (1.05% missing emails),
-- everything else PASS.
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;
CALL neobank.governance.run_dq_checks();

SELECT r.rule_id, r.cde, r.dimension, r.check_desc, d.measured_value, d.threshold_max, d.status, r.owner
FROM neobank.governance.dq_results d
JOIN neobank.governance.dq_rules r ON r.rule_id = d.rule_id
WHERE d.run_at = (SELECT MAX(run_at) FROM neobank.governance.dq_results)
ORDER BY r.rule_id;

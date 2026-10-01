-- =============================================================================
-- 09_audit_queries.sql
-- Evidence for auditors: each query answers one question an internal auditor,
-- the DPO or a regulator would ask. Run them one at a time (Ctrl+Enter).
--
-- Most queries run as FR_AUDITOR, which can read governance tables and
-- Snowflake's governance views, but no customer data.
--
-- Views in SNOWFLAKE.ACCOUNT_USAGE lag behind by up to 2-3 hours. The
-- INFORMATION_SCHEMA table functions used in Q2 are immediate.
-- =============================================================================

USE WAREHOUSE neobank_wh;
USE SECONDARY ROLES NONE;


-- -----------------------------------------------------------------------------
-- Q1. Who may see unmasked personal data, why, and which users hold that role?
-- Note: SYSADMIN is the pipeline role. No person holds it directly, but anyone
-- with ACCOUNTADMIN can switch to it, so ACCOUNTADMIN must stay with a few
-- named administrators.
-- -----------------------------------------------------------------------------
USE ROLE fr_auditor;
SELECT a.role_name, a.reason, a.approved_by, g.grantee_name AS user_holding_role
FROM neobank.governance.pii_access a
LEFT JOIN snowflake.account_usage.grants_to_users g
  ON g.role = a.role_name
 AND g.deleted_on IS NULL
ORDER BY a.role_name;


-- -----------------------------------------------------------------------------
-- Q2. Where is personal data, and is every column protected?
-- One row per protected column. POLICY_STATUS must be ACTIVE everywhere.
-- -----------------------------------------------------------------------------
USE ROLE governance_admin;
SELECT ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name AS table_name,
       ref_column_name, policy_kind, policy_name, tag_name, policy_status
FROM (
              SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.raw.customers',                ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.raw.accounts',                 ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.raw.transactions',             ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.governance.customer_identity', ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.core.customers',               ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.core.accounts',                ref_entity_domain => 'table'))
    UNION ALL SELECT * FROM TABLE(neobank.information_schema.policy_references(ref_entity_name => 'neobank.core.transactions',            ref_entity_domain => 'table'))
)
ORDER BY policy_kind, table_name, ref_column_name;


-- -----------------------------------------------------------------------------
-- Q3. Which job role holds which access roles? (the role design on one page)
-- -----------------------------------------------------------------------------
USE ROLE fr_auditor;
SELECT grantee_name AS functional_role, name AS access_role
FROM snowflake.account_usage.grants_to_roles
WHERE granted_on = 'ROLE'
  AND privilege = 'USAGE'
  AND deleted_on IS NULL
  AND (grantee_name LIKE 'FR_%' OR grantee_name = 'GOVERNANCE_ADMIN')
ORDER BY functional_role, access_role;


-- -----------------------------------------------------------------------------
-- Q4. Who read the identity vault in the last 7 days?
-- ACCESS_HISTORY records every object and column a query touched.
-- -----------------------------------------------------------------------------
USE ROLE fr_auditor;
SELECT ah.query_start_time, ah.user_name, obj.value:"objectName"::STRING AS object_name
FROM snowflake.account_usage.access_history ah,
     LATERAL FLATTEN(input => ah.base_objects_accessed) obj
WHERE obj.value:"objectName"::STRING = 'NEOBANK.GOVERNANCE.CUSTOMER_IDENTITY'
  AND ah.query_start_time > DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER BY ah.query_start_time DESC;


-- -----------------------------------------------------------------------------
-- Q5. Erasure requests: what was decided, and on which legal basis?
-- -----------------------------------------------------------------------------
USE ROLE fr_auditor;
SELECT decision, COUNT(*) AS requests, MIN(decided_at) AS first_decided, MAX(decided_at) AS last_decided
FROM neobank.governance.erasure_log
GROUP BY decision
ORDER BY decision;


-- -----------------------------------------------------------------------------
-- Q6. Proof of erasure: for every ERASED request, nothing is left.
-- Matches on the hash, because the log never stores the customer ID.
-- Expected: 0 everywhere.
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;
SELECT l.request_id,
       COUNT(DISTINCT r.customer_id) AS raw_rows_left,
       COUNT(DISTINCT v.customer_id) AS vault_rows_left
FROM neobank.governance.erasure_log l
LEFT JOIN neobank.raw.customers r
  ON SHA2(r.customer_id, 256) = l.customer_id_hash
LEFT JOIN neobank.governance.customer_identity v
  ON SHA2(v.customer_id, 256) = l.customer_id_hash
WHERE l.decision = 'ERASED'
GROUP BY l.request_id;


-- -----------------------------------------------------------------------------
-- Q7. Storage limitation: customers whose retention period has ended but who
-- are still stored. GDPR Art. 5(1)(e) requires deleting them without waiting
-- for a request; GwG §8(4) also sets an upper limit of 10 years.
-- Each one should go through process_erasure_request.
-- -----------------------------------------------------------------------------
USE ROLE fr_privacy_officer;
SELECT COUNT(*) AS customers_past_retention,
       MIN(closed_at) AS oldest_closure
FROM neobank.core.customers
WHERE closed_at IS NOT NULL
  AND DATEADD(year,
              (SELECT MAX(retention_years) FROM neobank.governance.retention_rules),
              DATE_FROM_PARTS(YEAR(closed_at), 12, 31)) < CURRENT_DATE();


-- -----------------------------------------------------------------------------
-- Q8. Re-identification risk in the pseudonymised core (k-anonymity).
-- Pseudonymised data is still personal data (GDPR Recital 26): rare
-- combinations of ordinary fields can point to one person. A group smaller
-- than 5 customers is treated as a risk.
-- Shows why the full onboarding timestamp should not be shared with analysts
-- outside the bank: adding it makes most customers unique.
-- -----------------------------------------------------------------------------
USE ROLE fr_privacy_officer;
WITH by_year_country AS (
    SELECT birth_year, country_code, COUNT(*) AS n
    FROM neobank.core.customers
    GROUP BY birth_year, country_code
),
by_year_country_month AS (
    SELECT birth_year, country_code, DATE_TRUNC('month', onboarded_at) AS onboarded_month, COUNT(*) AS n
    FROM neobank.core.customers
    GROUP BY birth_year, country_code, onboarded_month
)
SELECT 'birth year + country' AS quasi_identifiers,
       COUNT(*) AS groups, COUNT_IF(n < 5) AS groups_below_5, SUM(IFF(n < 5, n, 0)) AS customers_at_risk
FROM by_year_country
UNION ALL
SELECT 'birth year + country + onboarding month',
       COUNT(*), COUNT_IF(n < 5), SUM(IFF(n < 5, n, 0))
FROM by_year_country_month;


-- -----------------------------------------------------------------------------
-- Q9. Data quality on Critical Data Elements: latest result per rule
-- -----------------------------------------------------------------------------
USE ROLE fr_auditor;
SELECT r.rule_id, r.cde, r.dimension, d.measured_value, d.threshold_max, d.status, r.owner, d.run_at
FROM neobank.governance.dq_results d
JOIN neobank.governance.dq_rules r ON r.rule_id = d.rule_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY d.rule_id ORDER BY d.run_at DESC) = 1
ORDER BY d.status, r.rule_id;

USE SECONDARY ROLES ALL;

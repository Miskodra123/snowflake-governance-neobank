-- =============================================================================
-- 04_classification.sql
-- Know where personal data sits: our own tags, plus Snowflake's automatic
-- classification as a second opinion.
--
--   pii_type    which kind of personal data a column holds. The masking
--               policies in 05 hang on this tag, so tagging a column = protecting it.
--   data_owner  the accountable business owner of a table (see governance/ownership.yml)
--   cde         marks Critical Data Elements (see governance/cde_register.yml)
--
-- Automatic classification (SYSTEM$CLASSIFY) scans the data and suggests which
-- columns are identifiers. It is used here as a control, not as the decision:
-- the last query lists any column Snowflake thinks is an identifier but that has
-- no pii_type tag, i.e. personal data that would not be masked.
--
-- Note: 01 uses CREATE OR REPLACE for raw tables. Rerunning 01 drops these tags,
-- so rerun 04 after it.
--
-- Run as: GOVERNANCE_ADMIN (tags), ACCOUNTADMIN (classification). Rerunnable.
-- =============================================================================

USE ROLE governance_admin;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.governance;


-- -----------------------------------------------------------------------------
-- 1. Tags. ALLOWED_VALUES stops typos such as 'Email' vs 'EMAIL'.
-- -----------------------------------------------------------------------------
CREATE TAG IF NOT EXISTS pii_type
    ALLOWED_VALUES 'NAME', 'EMAIL', 'PHONE', 'DATE_OF_BIRTH', 'TAX_ID', 'ADDRESS', 'IBAN'
    COMMENT = 'Kind of personal data in a column. Drives the masking policies in 05.';

CREATE TAG IF NOT EXISTS data_owner
    COMMENT = 'Accountable business owner of a table. Source: governance/ownership.yml';

CREATE TAG IF NOT EXISTS cde
    ALLOWED_VALUES 'YES'
    COMMENT = 'Critical Data Element. Source: governance/cde_register.yml';


-- -----------------------------------------------------------------------------
-- 2. Tag personal data columns
-- -----------------------------------------------------------------------------
ALTER TABLE neobank.raw.customers MODIFY
    COLUMN first_name     SET TAG pii_type = 'NAME',
    COLUMN last_name      SET TAG pii_type = 'NAME',
    COLUMN email          SET TAG pii_type = 'EMAIL',
    COLUMN phone          SET TAG pii_type = 'PHONE',
    COLUMN date_of_birth  SET TAG pii_type = 'DATE_OF_BIRTH',
    COLUMN tax_id         SET TAG pii_type = 'TAX_ID',
    COLUMN street_address SET TAG pii_type = 'ADDRESS',
    COLUMN postcode       SET TAG pii_type = 'ADDRESS';

ALTER TABLE neobank.raw.accounts MODIFY
    COLUMN iban SET TAG pii_type = 'IBAN';

-- Counterparty names are tagged too: for transfers they are private persons.
ALTER TABLE neobank.raw.transactions MODIFY
    COLUMN counterparty_name SET TAG pii_type = 'NAME',
    COLUMN counterparty_iban SET TAG pii_type = 'IBAN';

ALTER TABLE neobank.governance.customer_identity MODIFY
    COLUMN first_name     SET TAG pii_type = 'NAME',
    COLUMN last_name      SET TAG pii_type = 'NAME',
    COLUMN email          SET TAG pii_type = 'EMAIL',
    COLUMN phone          SET TAG pii_type = 'PHONE',
    COLUMN date_of_birth  SET TAG pii_type = 'DATE_OF_BIRTH',
    COLUMN tax_id         SET TAG pii_type = 'TAX_ID',
    COLUMN street_address SET TAG pii_type = 'ADDRESS',
    COLUMN postcode       SET TAG pii_type = 'ADDRESS';


-- -----------------------------------------------------------------------------
-- 3. Ownership: every table has one accountable owner
-- -----------------------------------------------------------------------------
ALTER TABLE neobank.raw.customers                SET TAG data_owner = 'Head of Customer Onboarding';
ALTER TABLE neobank.raw.accounts                 SET TAG data_owner = 'Head of Retail Banking';
ALTER TABLE neobank.raw.transactions             SET TAG data_owner = 'Head of Payments';
ALTER TABLE neobank.raw.consents                 SET TAG data_owner = 'Data Protection Officer';
ALTER TABLE neobank.core.customers               SET TAG data_owner = 'Head of Customer Onboarding';
ALTER TABLE neobank.core.accounts                SET TAG data_owner = 'Head of Retail Banking';
ALTER TABLE neobank.core.transactions            SET TAG data_owner = 'Head of Payments';
ALTER TABLE neobank.core.consents                SET TAG data_owner = 'Data Protection Officer';
ALTER TABLE neobank.governance.customer_identity SET TAG data_owner = 'Data Protection Officer';
ALTER TABLE neobank.governance.erasure_log       SET TAG data_owner = 'Data Protection Officer';


-- -----------------------------------------------------------------------------
-- 4. Critical Data Elements (details and rules in governance/cde_register.yml)
-- -----------------------------------------------------------------------------
ALTER TABLE neobank.core.transactions MODIFY
    COLUMN amount       SET TAG cde = 'YES',
    COLUMN booked_at    SET TAG cde = 'YES';

ALTER TABLE neobank.core.accounts MODIFY
    COLUMN status       SET TAG cde = 'YES';

ALTER TABLE neobank.core.customers MODIFY
    COLUMN legal_entity SET TAG cde = 'YES',
    COLUMN kyc_status   SET TAG cde = 'YES';

ALTER TABLE neobank.governance.customer_identity MODIFY
    COLUMN email        SET TAG cde = 'YES';


-- -----------------------------------------------------------------------------
-- 5. Automatic classification of the raw tables
-- Snowflake samples each column and sets its own system tags:
--   SNOWFLAKE.CORE.SEMANTIC_CATEGORY  e.g. NAME, EMAIL, DATE_OF_BIRTH
--   SNOWFLAKE.CORE.PRIVACY_CATEGORY   IDENTIFIER, QUASI_IDENTIFIER or SENSITIVE
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CALL SYSTEM$CLASSIFY('neobank.raw.customers',    {'auto_tag': true});
CALL SYSTEM$CLASSIFY('neobank.raw.accounts',     {'auto_tag': true});
CALL SYSTEM$CLASSIFY('neobank.raw.transactions', {'auto_tag': true});


-- -----------------------------------------------------------------------------
-- 6. Coverage check: compare Snowflake's classification with our tags
-- GAP    = Snowflake sees an identifier we did not tag. It would not be masked.
-- REVIEW = quasi-identifier (e.g. city, birth date). Not masked on its own, but
--          relevant for re-identification risk.
-- -----------------------------------------------------------------------------
WITH refs AS (
    SELECT 'RAW.CUSTOMERS' AS table_name, column_name, tag_name, tag_value
    FROM TABLE(neobank.information_schema.tag_references_all_columns('neobank.raw.customers', 'table'))
    UNION ALL
    SELECT 'RAW.ACCOUNTS', column_name, tag_name, tag_value
    FROM TABLE(neobank.information_schema.tag_references_all_columns('neobank.raw.accounts', 'table'))
    UNION ALL
    SELECT 'RAW.TRANSACTIONS', column_name, tag_name, tag_value
    FROM TABLE(neobank.information_schema.tag_references_all_columns('neobank.raw.transactions', 'table'))
)
SELECT
    table_name,
    column_name,
    MAX(IFF(tag_name = 'SEMANTIC_CATEGORY', tag_value, NULL)) AS snowflake_semantic,
    MAX(IFF(tag_name = 'PRIVACY_CATEGORY',  tag_value, NULL)) AS snowflake_privacy,
    MAX(IFF(tag_name = 'PII_TYPE',          tag_value, NULL)) AS our_pii_type,
    CASE
        WHEN snowflake_privacy = 'IDENTIFIER'       AND our_pii_type IS NULL THEN 'GAP'
        WHEN snowflake_privacy = 'QUASI_IDENTIFIER' AND our_pii_type IS NULL THEN 'REVIEW'
        ELSE 'OK'
    END AS status
FROM refs
GROUP BY table_name, column_name
ORDER BY status, table_name, column_name;

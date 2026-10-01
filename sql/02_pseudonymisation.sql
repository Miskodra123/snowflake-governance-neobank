-- =============================================================================
-- 02_pseudonymisation.sql
-- Split personal data from everything else.
--
--   governance.customer_identity  the "identity vault": one row per customer with
--                                 a random token and all direct identifiers
--                                 (name, email, phone, tax ID, address, birth date)
--   core.*                        analytical tables keyed by the token only
--
-- Right to be forgotten (built in 08): delete the customer's row from the vault.
-- The token in core then points to nothing, so the remaining data can no longer
-- be linked to a person.
--
-- Run as: SYSADMIN. Rerunnable.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE neobank_wh;
USE DATABASE neobank;


-- -----------------------------------------------------------------------------
-- 1. Identity vault
-- The token is a random UUID, not a hash of the customer ID. Anyone who knows a
-- customer ID could recompute its hash and re-link the data, even after the vault
-- row is deleted. A random token has no mathematical link to the person, so
-- deleting the vault row really breaks the link.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.customer_identity (
    customer_token  STRING        NOT NULL COMMENT 'Random UUID used in core instead of the customer ID',
    customer_id     STRING        NOT NULL COMMENT 'Source system customer ID',
    first_name      STRING,
    last_name       STRING,
    email           STRING,
    phone           STRING,
    date_of_birth   DATE,
    tax_id          STRING,
    street_address  STRING,
    postcode        STRING,
    city            STRING,
    tokenised_at    TIMESTAMP_NTZ NOT NULL COMMENT 'When the token was first assigned',
    restricted_until DATE         COMMENT 'Set by 08 when erasure is blocked by a retention law. Contact data is erased, the rest is kept until this date.',
    CONSTRAINT pk_customer_identity PRIMARY KEY (customer_token)
)
COMMENT = 'Identity vault: token to real customer. Deleting a row erases the link for that customer.';


-- -----------------------------------------------------------------------------
-- 2. Erasure log
-- One row per erasure request and its outcome (filled by 08). It stores a SHA-256
-- hash of the customer ID, never the ID itself. Step 3 uses it as a suppression
-- list: if raw data for an erased customer is ever loaded again, that customer
-- does not get a new token and does not come back.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS governance.erasure_log (
    request_id        STRING        NOT NULL,
    customer_id_hash  STRING        NOT NULL COMMENT 'SHA-256 of the customer ID',
    requested_at      TIMESTAMP_NTZ NOT NULL,
    decided_at        TIMESTAMP_NTZ,
    decision          STRING        COMMENT 'ERASED or RETAINED (legal retention applies)',
    legal_basis       STRING        COMMENT 'Why: GDPR Art. 17(1), or the retention law that blocks erasure',
    executed_by       STRING        COMMENT 'Role that executed the request',
    CONSTRAINT pk_erasure_log PRIMARY KEY (request_id)
)
COMMENT = 'Audit trail of erasure requests. Also a suppression list for re-ingestion.';


-- -----------------------------------------------------------------------------
-- 3. Assign tokens
-- MERGE keeps tokens stable: a customer gets a token once, and reruns only add
-- new customers. Existing rows get their personal data refreshed from raw,
-- except restricted customers: their erased contact data must not come back.
-- Customers with decision = 'ERASED' in the log are skipped.
-- -----------------------------------------------------------------------------
MERGE INTO governance.customer_identity AS t
USING (
    SELECT r.*
    FROM raw.customers r
    WHERE SHA2(r.customer_id, 256) NOT IN (
        SELECT customer_id_hash FROM governance.erasure_log WHERE decision = 'ERASED'
    )
) AS s
ON t.customer_id = s.customer_id
WHEN MATCHED AND t.restricted_until IS NULL THEN UPDATE SET
    first_name     = s.first_name,
    last_name      = s.last_name,
    email          = s.email,
    phone          = s.phone,
    date_of_birth  = s.date_of_birth,
    tax_id         = s.tax_id,
    street_address = s.street_address,
    postcode       = s.postcode,
    city           = s.city
WHEN NOT MATCHED THEN INSERT (
    customer_token, customer_id, first_name, last_name, email, phone,
    date_of_birth, tax_id, street_address, postcode, city, tokenised_at
) VALUES (
    UUID_STRING(), s.customer_id, s.first_name, s.last_name, s.email, s.phone,
    s.date_of_birth, s.tax_id, s.street_address, s.postcode, s.city,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);


-- -----------------------------------------------------------------------------
-- 4. Core tables (pseudonymised)
-- Tables are created once with explicit columns, then reloaded with
-- INSERT OVERWRITE. CREATE OR REPLACE would drop the table and with it the tags,
-- masking and row access policies attached in 04-06. INSERT OVERWRITE replaces
-- the rows but keeps the table and its governance settings.
--
-- Data minimisation: core keeps only what analysis needs.
--   date of birth   -> birth year
--   address, city   -> dropped, country is enough
--   IBAN            -> dropped, IBAN country kept
--   names of people in transfers -> dropped, merchant names kept
--
-- Every load joins to the vault, so a customer without a vault row (erased)
-- drops out of core automatically.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.customers (
    customer_token  STRING        NOT NULL,
    birth_year      NUMBER(4)     COMMENT 'Year only. Full date of birth stays in the vault.',
    country_code    STRING,
    legal_entity    STRING        COMMENT 'NEOBANK_DE or NEOBANK_EU. Used by row access policies.',
    kyc_status      STRING,
    onboarded_at    TIMESTAMP_NTZ,
    closed_at       TIMESTAMP_NTZ,
    _loaded_at      TIMESTAMP_NTZ
)
COMMENT = 'Pseudonymised customers. No direct identifiers.';

CREATE TABLE IF NOT EXISTS core.accounts (
    account_id      STRING        NOT NULL,
    customer_token  STRING        NOT NULL,
    iban_country    STRING        COMMENT 'Country prefix of the IBAN. Full IBAN stays in raw.',
    product         STRING,
    currency        STRING,
    legal_entity    STRING,
    opened_at       TIMESTAMP_NTZ,
    closed_at       TIMESTAMP_NTZ,
    status          STRING,
    _loaded_at      TIMESTAMP_NTZ
)
COMMENT = 'Pseudonymised accounts. No IBANs.';

CREATE TABLE IF NOT EXISTS core.transactions (
    transaction_id     STRING        NOT NULL,
    account_id         STRING        NOT NULL,
    booked_at          TIMESTAMP_NTZ,
    category           STRING,
    direction          STRING,
    channel            STRING,
    amount             NUMBER(12, 2),
    currency           STRING,
    counterparty_type  STRING        COMMENT 'MERCHANT, EMPLOYER or PERSON',
    counterparty_name  STRING        COMMENT 'Kept for merchants and employers, NULL for private persons',
    legal_entity       STRING        COMMENT 'From the account. Used by row access policies.',
    _loaded_at         TIMESTAMP_NTZ
)
COMMENT = 'Transactions without counterparty IBANs or names of private persons.';

CREATE TABLE IF NOT EXISTS core.consents (
    customer_token  STRING        NOT NULL,
    consent_type    STRING        NOT NULL,
    is_granted      BOOLEAN,
    recorded_at     TIMESTAMP_NTZ,
    _loaded_at      TIMESTAMP_NTZ
)
COMMENT = 'Consent choices keyed by token.';


INSERT OVERWRITE INTO core.customers
SELECT
    m.customer_token,
    YEAR(r.date_of_birth),
    r.country_code,
    r.legal_entity,
    r.kyc_status,
    r.onboarded_at,
    r.closed_at,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM raw.customers r
JOIN governance.customer_identity m
  ON m.customer_id = r.customer_id;

INSERT OVERWRITE INTO core.accounts
SELECT
    a.account_id,
    m.customer_token,
    LEFT(a.iban, 2),
    a.product,
    a.currency,
    a.legal_entity,
    a.opened_at,
    a.closed_at,
    a.status,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM raw.accounts a
JOIN governance.customer_identity m
  ON m.customer_id = a.customer_id;

INSERT OVERWRITE INTO core.transactions
SELECT
    transaction_id,
    account_id,
    booked_at,
    category,
    direction,
    channel,
    amount,
    currency,
    counterparty_type,
    IFF(counterparty_type = 'PERSON', NULL, counterparty_name),
    legal_entity,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM (
    SELECT
        t.*,
        a.legal_entity,
        CASE
            WHEN t.category IN ('TRANSFER_OUT', 'TRANSFER_IN') THEN 'PERSON'
            WHEN t.category = 'SALARY' THEN 'EMPLOYER'
            ELSE 'MERCHANT'
        END AS counterparty_type
    FROM raw.transactions t
    JOIN raw.accounts a
      ON a.account_id = t.account_id
    JOIN governance.customer_identity m
      ON m.customer_id = a.customer_id
);

INSERT OVERWRITE INTO core.consents
SELECT
    m.customer_token,
    c.consent_type,
    c.is_granted,
    c.recorded_at,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM raw.consents c
JOIN governance.customer_identity m
  ON m.customer_id = c.customer_id
WHERE m.restricted_until IS NULL;   -- consents of restricted customers were erased in 08


-- -----------------------------------------------------------------------------
-- 5. Check the result
-- Expected: vault rows = distinct tokens = core customers = 10,000;
-- accounts 13,316; transactions 300,000; consents 30,000;
-- 0 person names left in core transactions.
-- Rerun the whole script: the counts stay the same and tokens do not change.
-- -----------------------------------------------------------------------------
SELECT 'vault rows'                        AS check_name, COUNT(*) AS value FROM governance.customer_identity
UNION ALL SELECT 'distinct tokens',                     COUNT(DISTINCT customer_token) FROM governance.customer_identity
UNION ALL SELECT 'core customers',                      COUNT(*) FROM core.customers
UNION ALL SELECT 'core accounts',                       COUNT(*) FROM core.accounts
UNION ALL SELECT 'core transactions',                   COUNT(*) FROM core.transactions
UNION ALL SELECT 'core consents',                       COUNT(*) FROM core.consents
UNION ALL SELECT 'person names left in core',           COUNT_IF(counterparty_type = 'PERSON' AND counterparty_name IS NOT NULL) FROM core.transactions;

-- What an analyst sees: a token instead of a person.
SELECT * FROM core.customers LIMIT 5;

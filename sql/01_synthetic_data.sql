-- =============================================================================
-- 01_synthetic_data.sql
-- Fake neobank data in the RAW zone: customers, accounts, transactions, consents.
--
-- Run as: SYSADMIN. Rerunnable: CREATE OR REPLACE rebuilds the same data.
--
-- How the fake values are made:
--   GENERATOR(ROWCOUNT => n) produces n empty rows, ROW_NUMBER() numbers them.
--   HASH(row_number, 'label') turns each number into a large pseudo-random integer.
--   A different label per column keeps the columns independent of each other.
--   Because HASH is deterministic, every rerun produces exactly the same data.
--
-- Defects added on purpose, so the quality checks in 07 have something to find:
--   ~1% of customers have no email
--   ~0.1% of transactions have a negative amount
--
-- RAW still holds real identifiers (names, emails, IBANs). They are replaced by
-- tokens in 02_pseudonymisation.sql. Tables created in the transient RAW schema
-- are transient too, so they have no Fail-safe.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.raw;


-- -----------------------------------------------------------------------------
-- 1. Customers (10,000)
-- Two legal entities: NEOBANK_DE for German customers, NEOBANK_EU for the
-- branches in France, Spain, Italy and the Netherlands. Row access policies
-- in 06 use this column.
-- About 8% of customers have closed their relationship. Those are the
-- interesting cases for the right to be forgotten in 08.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE customers
    COMMENT = 'Synthetic customers as landed from the core banking system. Contains direct identifiers.'
AS
WITH lists AS (
    SELECT
        ARRAY_CONSTRUCT('Anna', 'Lukas', 'Sophie', 'Jonas', 'Marie', 'Felix', 'Lea', 'Paul', 'Emma', 'Leon',
                        'Camille', 'Hugo', 'Lucia', 'Mateo', 'Giulia', 'Marco', 'Sanne', 'Daan', 'Ines', 'Tomas') AS first_names,
        ARRAY_CONSTRUCT('Mueller', 'Schmidt', 'Schneider', 'Fischer', 'Weber', 'Meyer', 'Wagner', 'Becker', 'Hoffmann', 'Schulz',
                        'Martin', 'Bernard', 'Garcia', 'Lopez', 'Rossi', 'Russo', 'de Jong', 'Jansen', 'Novak', 'Kovac') AS last_names,
        ARRAY_CONSTRUCT('Hauptstrasse', 'Bahnhofstrasse', 'Gartenweg', 'Schulstrasse', 'Lindenallee',
                        'Rue de la Paix', 'Calle Mayor', 'Via Roma', 'Kerkstraat', 'Dorfplatz') AS streets
),
base AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 10000))
),
people AS (
    SELECT
        b.n,
        l.first_names[MOD(ABS(HASH(b.n, 'first')), ARRAY_SIZE(l.first_names))]::STRING AS first_name,
        l.last_names[MOD(ABS(HASH(b.n, 'last')), ARRAY_SIZE(l.last_names))]::STRING    AS last_name,
        l.streets[MOD(ABS(HASH(b.n, 'street')), ARRAY_SIZE(l.streets))]::STRING       AS street_name,
        MOD(ABS(HASH(b.n, 'country')), 100) AS country_roll,
        CASE
            WHEN country_roll < 50 THEN 'DE'
            WHEN country_roll < 70 THEN 'FR'
            WHEN country_roll < 85 THEN 'ES'
            WHEN country_roll < 95 THEN 'IT'
            ELSE 'NL'
        END AS country_code,
        DATEADD(second,
                MOD(ABS(HASH(b.n, 'onboarded')), DATEDIFF(second, '2016-01-01'::TIMESTAMP_NTZ, '2026-09-01'::TIMESTAMP_NTZ)),
                '2016-01-01'::TIMESTAMP_NTZ) AS onboarded_at
    FROM base b
    CROSS JOIN lists l
)
SELECT
    'C' || LPAD(n::STRING, 7, '0')                                   AS customer_id,
    first_name,
    last_name,
    CASE
        WHEN MOD(ABS(HASH(n, 'email_defect')), 100) = 0 THEN NULL    -- seeded defect, ~1%
        ELSE LOWER(first_name || '.' || REPLACE(last_name, ' ', '') || n::STRING || '@example.com')
    END                                                              AS email,
    CASE country_code
        WHEN 'DE' THEN '+49' WHEN 'FR' THEN '+33' WHEN 'ES' THEN '+34'
        WHEN 'IT' THEN '+39' ELSE '+31'
    END || ' 1' || LPAD(MOD(ABS(HASH(n, 'phone')), 1000000000)::STRING, 9, '0')
                                                                     AS phone,
    DATEADD(day, -MOD(ABS(HASH(n, 'dob')), 365 * 60), '2008-01-01'::DATE)
                                                                     AS date_of_birth,
    LPAD(MOD(ABS(HASH(n, 'tax')), 100000000000)::STRING, 11, '0')    AS tax_id,
    street_name || ' ' || (MOD(ABS(HASH(n, 'house')), 120) + 1)::STRING
                                                                     AS street_address,
    LPAD(MOD(ABS(HASH(n, 'postcode')), 100000)::STRING, 5, '0')      AS postcode,
    CASE country_code
        WHEN 'DE' THEN ARRAY_CONSTRUCT('Berlin', 'Hamburg', 'Munich', 'Cologne', 'Frankfurt')[MOD(ABS(HASH(n, 'city')), 5)]::STRING
        WHEN 'FR' THEN ARRAY_CONSTRUCT('Paris', 'Lyon', 'Marseille')[MOD(ABS(HASH(n, 'city')), 3)]::STRING
        WHEN 'ES' THEN ARRAY_CONSTRUCT('Madrid', 'Barcelona', 'Valencia')[MOD(ABS(HASH(n, 'city')), 3)]::STRING
        WHEN 'IT' THEN ARRAY_CONSTRUCT('Rome', 'Milan', 'Turin')[MOD(ABS(HASH(n, 'city')), 3)]::STRING
        ELSE           ARRAY_CONSTRUCT('Amsterdam', 'Rotterdam', 'Utrecht')[MOD(ABS(HASH(n, 'city')), 3)]::STRING
    END                                                              AS city,
    country_code,
    IFF(country_code = 'DE', 'NEOBANK_DE', 'NEOBANK_EU')             AS legal_entity,
    CASE
        WHEN MOD(ABS(HASH(n, 'kyc')), 100) < 95 THEN 'VERIFIED'
        WHEN MOD(ABS(HASH(n, 'kyc')), 100) < 99 THEN 'PENDING'
        ELSE 'REJECTED'
    END                                                              AS kyc_status,
    onboarded_at,
    CASE
        WHEN MOD(ABS(HASH(n, 'closed')), 100) < 8
        THEN DATEADD(day,
                     30 + MOD(ABS(HASH(n, 'closed_days')),
                              GREATEST(DATEDIFF(day, onboarded_at, '2026-09-01'::TIMESTAMP_NTZ) - 30, 1)),
                     onboarded_at)
    END                                                              AS closed_at,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                               AS _loaded_at
FROM people;


-- -----------------------------------------------------------------------------
-- 2. Accounts (~13,000)
-- Every customer has a current account, about a third also a savings account.
-- Fake IBANs: real country prefix and real length, but check digits are always
-- '00'. Valid IBAN check digits run from 02 to 98, so these can never pass
-- validation and can never be mistaken for a real account.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE accounts
    COMMENT = 'Synthetic bank accounts. IBANs use check digits 00 and are always invalid.'
AS
WITH candidates AS (
    SELECT c.customer_id, c.country_code, c.legal_entity, c.onboarded_at, c.closed_at, x.account_no
    FROM customers c
    CROSS JOIN (SELECT 1 AS account_no UNION ALL SELECT 2) x
    WHERE x.account_no = 1
       OR MOD(ABS(HASH(c.customer_id, 'second_account')), 3) = 0
),
numbered AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY customer_id, account_no) AS n,
        *
    FROM candidates
)
SELECT
    'A' || LPAD(n::STRING, 8, '0')                                   AS account_id,
    customer_id,
    country_code || '00' ||
        SUBSTR(LPAD(MOD(ABS(HASH(n, 'iban1')), 1000000000000)::STRING, 12, '0') ||
               LPAD(MOD(ABS(HASH(n, 'iban2')), 1000000000000)::STRING, 12, '0'),
               1,
               CASE country_code
                   WHEN 'DE' THEN 18 WHEN 'FR' THEN 23 WHEN 'ES' THEN 20
                   WHEN 'IT' THEN 23 ELSE 14
               END)                                                  AS iban,
    IFF(account_no = 1, 'CURRENT', 'SAVINGS')                        AS product,
    'EUR'                                                            AS currency,
    legal_entity,
    IFF(account_no = 1,
        onboarded_at,
        DATEADD(day,
                MOD(ABS(HASH(n, 'opened')),
                    GREATEST(DATEDIFF(day, onboarded_at, COALESCE(closed_at, '2026-09-01'::TIMESTAMP_NTZ)), 1)),
                onboarded_at))                                       AS opened_at,
    closed_at,
    IFF(closed_at IS NULL, 'OPEN', 'CLOSED')                         AS status,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                               AS _loaded_at
FROM numbered;


-- -----------------------------------------------------------------------------
-- 3. Transactions (300,000)
-- Each transaction picks a random account and a date while that account was open.
-- Outgoing transfers name a person as counterparty: personal data hides in
-- transaction tables too, which is why classification in 04 scans every table.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE transactions
    COMMENT = 'Synthetic card payments, transfers and salary credits. Amounts in EUR.'
AS
WITH acct AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY account_id)                      AS acct_n,
        account_id,
        opened_at,
        COALESCE(closed_at, '2026-09-30'::TIMESTAMP_NTZ)             AS active_until
    FROM accounts
),
acct_count AS (
    SELECT COUNT(*) AS cnt FROM acct
),
base AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 300000))
),
picked AS (
    SELECT
        b.n,
        a.account_id,
        a.opened_at,
        a.active_until,
        MOD(ABS(HASH(b.n, 'category')), 100) AS category_roll,
        CASE
            WHEN category_roll < 30 THEN 'GROCERIES'
            WHEN category_roll < 50 THEN 'RESTAURANTS'
            WHEN category_roll < 60 THEN 'TRAVEL'
            WHEN category_roll < 70 THEN 'UTILITIES'
            WHEN category_roll < 85 THEN 'TRANSFER_OUT'
            WHEN category_roll < 95 THEN 'TRANSFER_IN'
            ELSE 'SALARY'
        END AS category
    FROM base b
    CROSS JOIN acct_count c
    JOIN acct a
      ON a.acct_n = MOD(ABS(HASH(b.n, 'account')), c.cnt) + 1
)
SELECT
    'T' || LPAD(n::STRING, 9, '0')                                   AS transaction_id,
    account_id,
    DATEADD(second,
            MOD(ABS(HASH(n, 'booked')), GREATEST(DATEDIFF(second, opened_at, active_until), 1)),
            opened_at)                                               AS booked_at,
    category,
    IFF(category IN ('TRANSFER_IN', 'SALARY'), 'CREDIT', 'DEBIT')    AS direction,
    CASE
        WHEN category IN ('GROCERIES', 'RESTAURANTS', 'TRAVEL') THEN 'CARD'
        WHEN category = 'UTILITIES' THEN 'DIRECT_DEBIT'
        WHEN category = 'SALARY' THEN 'SEPA_TRANSFER'
        WHEN MOD(ABS(HASH(n, 'instant')), 2) = 0 THEN 'SEPA_INSTANT'
        ELSE 'SEPA_TRANSFER'
    END                                                              AS channel,
    CASE
        WHEN MOD(ABS(HASH(n, 'amount_defect')), 1000) = 0 THEN -1    -- seeded defect, ~0.1%
        ELSE 1
    END
    * IFF(category = 'SALARY',
          1800 + MOD(ABS(HASH(n, 'salary')), 4000),
          ROUND(POWER(10, MOD(ABS(HASH(n, 'amount')), 3500) / 1000.0), 2))
                                                                     AS amount,
    'EUR'                                                            AS currency,
    CASE category
        WHEN 'GROCERIES'   THEN ARRAY_CONSTRUCT('REWE', 'Lidl', 'Carrefour', 'Mercadona', 'Esselunga', 'Albert Heijn')[MOD(ABS(HASH(n, 'merchant')), 6)]::STRING
        WHEN 'RESTAURANTS' THEN ARRAY_CONSTRUCT('Cafe Central', 'Pizzeria Napoli', 'Sushi Bar', 'Burger Point')[MOD(ABS(HASH(n, 'merchant')), 4)]::STRING
        WHEN 'TRAVEL'      THEN ARRAY_CONSTRUCT('Deutsche Bahn', 'Lufthansa', 'SNCF', 'Ryanair')[MOD(ABS(HASH(n, 'merchant')), 4)]::STRING
        WHEN 'UTILITIES'   THEN ARRAY_CONSTRUCT('Vattenfall', 'E.ON', 'Telekom', 'Vodafone')[MOD(ABS(HASH(n, 'merchant')), 4)]::STRING
        WHEN 'SALARY'      THEN ARRAY_CONSTRUCT('Acme Logistics GmbH', 'Nordwind Software SE', 'Sol Hotels SA')[MOD(ABS(HASH(n, 'merchant')), 3)]::STRING
        ELSE ARRAY_CONSTRUCT('Anna', 'Lukas', 'Sophie', 'Jonas', 'Camille', 'Mateo')[MOD(ABS(HASH(n, 'cp_first')), 6)]::STRING
             || ' ' ||
             ARRAY_CONSTRUCT('Mueller', 'Weber', 'Martin', 'Garcia', 'Rossi', 'Jansen')[MOD(ABS(HASH(n, 'cp_last')), 6)]::STRING
    END                                                              AS counterparty_name,
    IFF(category IN ('TRANSFER_OUT', 'TRANSFER_IN', 'SALARY'),
        'DE00' || LPAD(MOD(ABS(HASH(n, 'cp_iban1')), 1000000000)::STRING, 9, '0')
               || LPAD(MOD(ABS(HASH(n, 'cp_iban2')), 1000000000)::STRING, 9, '0'),
        NULL)                                                        AS counterparty_iban,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                               AS _loaded_at
FROM picked;


-- -----------------------------------------------------------------------------
-- 4. Consents (3 per customer)
-- What each customer agreed to at onboarding. Used later for consent-aware
-- access: data from customers who refused profiling stays out of profiling use.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE consents
    COMMENT = 'Consent choices per customer and purpose, recorded at onboarding.'
AS
SELECT
    c.customer_id,
    p.consent_type,
    MOD(ABS(HASH(c.customer_id, p.consent_type)), 100) < p.grant_pct AS is_granted,
    c.onboarded_at                                                    AS recorded_at,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                                AS _loaded_at
FROM customers c
CROSS JOIN (
    SELECT column1 AS consent_type, column2 AS grant_pct
    FROM VALUES ('MARKETING_EMAIL', 40), ('DATA_SHARING_PARTNERS', 15), ('PROFILING', 60)
) p;


-- -----------------------------------------------------------------------------
-- 5. Check the result
-- Expected: 10,000 customers, ~13,300 accounts, 300,000 transactions,
-- 30,000 consents, ~100 missing emails, ~300 negative amounts,
-- 0 IBANs with check digits other than 00.
-- -----------------------------------------------------------------------------
SELECT 'customers'                     AS check_name, COUNT(*) AS value FROM customers
UNION ALL SELECT 'accounts',                          COUNT(*)          FROM accounts
UNION ALL SELECT 'transactions',                      COUNT(*)          FROM transactions
UNION ALL SELECT 'consents',                          COUNT(*)          FROM consents
UNION ALL SELECT 'closed customers',                  COUNT_IF(closed_at IS NOT NULL) FROM customers
UNION ALL SELECT 'defect: missing email',             COUNT_IF(email IS NULL)         FROM customers
UNION ALL SELECT 'defect: negative amount',           COUNT_IF(amount < 0)            FROM transactions
UNION ALL SELECT 'IBANs not using check digits 00',   COUNT_IF(SUBSTR(iban, 3, 2) <> '00') FROM accounts;

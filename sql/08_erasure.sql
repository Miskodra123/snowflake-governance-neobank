-- =============================================================================
-- 08_erasure.sql
-- Right to be forgotten (GDPR Article 17), as a bank has to do it.
--
-- At a bank, erasure is not a single DELETE. The law that grants the right to
-- erasure also says it does not apply while another law requires the bank to
-- keep the data (Art. 17(3)(b)). So every request gets one of four outcomes:
--
--   NOT_FOUND   no identity record (unknown customer, or already erased)
--   RETAINED    the customer is still active: the data is needed for the contract
--   RESTRICTED  closed, but still inside a legal retention period: contact data
--               and consents are erased now, the rest is kept but restricted
--               until the period ends (GDPR Art. 18)
--   ERASED      closed and retention has ended: everything is deleted, and the
--               identity vault row last, which breaks the token link for good
--
-- Every decision is logged in governance.erasure_log with a hash of the
-- customer ID, never the ID itself. The log doubles as a suppression list:
-- 02_pseudonymisation will never issue a new token for an erased customer.
--
-- Run as: SYSADMIN (owns the procedure), SECURITYADMIN (grant), then the
-- demo runs as FR_PRIVACY_OFFICER. Rerunnable.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE neobank_wh;
USE SCHEMA neobank.governance;


-- -----------------------------------------------------------------------------
-- 1. Retention rules
-- Periods for a German bank. They start at the end of the calendar year in
-- which the business relationship ended.
-- Simplification: the procedure applies the longest period to the whole
-- customer record. A real bank sets periods per data category, confirmed by Legal.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retention_rules (
    rule_code        STRING NOT NULL,
    applies_to       STRING NOT NULL,
    retention_years  NUMBER(2) NOT NULL,
    legal_reference  STRING NOT NULL,
    CONSTRAINT pk_retention_rules PRIMARY KEY (rule_code)
)
COMMENT = 'Legal retention periods that can block erasure. To be confirmed by Legal.';

INSERT OVERWRITE INTO retention_rules VALUES
    ('AML_RECORDS',      'Customer identification and transaction records', 5,
     'GwG §8(4): 5 years from the end of the calendar year the business relationship ends'),
    ('BOOKING_VOUCHERS', 'Account statements and booking vouchers',          8,
     '§147 AO / §257 HGB: 8 years since the 4th Bureaucracy Relief Act (for BaFin-supervised firms one year later)');


-- -----------------------------------------------------------------------------
-- 2. The erasure procedure
-- EXECUTE AS OWNER: the privacy officer may run it, but cannot run the deletes
-- directly. The procedure is the only way in, and it always writes the log.
-- Everything runs in one transaction: either the whole request is processed
-- and logged, or nothing changes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE process_erasure_request(p_customer_id STRING)
    RETURNS STRING
    LANGUAGE SQL
    COMMENT = 'Processes a GDPR Art. 17 request: decides, erases or restricts, and logs the outcome'
    EXECUTE AS OWNER
AS
$$
DECLARE
    v_request_id    STRING;
    v_token         STRING;
    v_closed_at     TIMESTAMP_NTZ;
    v_years         NUMBER;
    v_retain_until  DATE;
    v_decision      STRING;
    v_basis         STRING;
BEGIN
    v_request_id := 'REQ-' || UUID_STRING();
    BEGIN TRANSACTION;

    SELECT MAX(customer_token) INTO :v_token
    FROM neobank.governance.customer_identity
    WHERE customer_id = :p_customer_id;

    IF (v_token IS NULL) THEN
        v_decision := 'NOT_FOUND';
        v_basis    := 'No identity record: unknown customer or already erased.';
    ELSE
        SELECT MAX(closed_at) INTO :v_closed_at
        FROM neobank.core.customers
        WHERE customer_token = :v_token;

        IF (v_closed_at IS NULL) THEN
            v_decision := 'RETAINED';
            v_basis    := 'Active business relationship: data is needed to perform the contract (GDPR Art. 6(1)(b)). '
                       || 'Erasure is possible after the account is closed and retention has ended.';
        ELSE
            SELECT MAX(retention_years) INTO :v_years FROM neobank.governance.retention_rules;
            v_retain_until := DATEADD(year, v_years, DATE_FROM_PARTS(YEAR(v_closed_at), 12, 31));

            IF (CURRENT_DATE() <= v_retain_until) THEN
                -- Partial erasure: what no retention law covers goes now.
                v_decision := 'RESTRICTED';
                v_basis    := 'GDPR Art. 17(3)(b): legal retention until ' || TO_CHAR(v_retain_until) || '. '
                           || 'Email, phone and consents erased now; remaining data restricted (Art. 18) until then.';

                UPDATE neobank.governance.customer_identity
                   SET email = NULL, phone = NULL, restricted_until = :v_retain_until
                 WHERE customer_token = :v_token;
                UPDATE neobank.raw.customers
                   SET email = NULL, phone = NULL
                 WHERE customer_id = :p_customer_id;
                DELETE FROM neobank.core.consents WHERE customer_token = :v_token;
                DELETE FROM neobank.raw.consents  WHERE customer_id   = :p_customer_id;
            ELSE
                -- Full erasure. Core first, then raw, the vault row last.
                v_decision := 'ERASED';
                v_basis    := 'GDPR Art. 17(1): retention period ended on ' || TO_CHAR(v_retain_until) || '. All records deleted.';

                DELETE FROM neobank.core.transactions
                 WHERE account_id IN (SELECT account_id FROM neobank.core.accounts WHERE customer_token = :v_token);
                DELETE FROM neobank.core.accounts  WHERE customer_token = :v_token;
                DELETE FROM neobank.core.consents  WHERE customer_token = :v_token;
                DELETE FROM neobank.core.customers WHERE customer_token = :v_token;

                DELETE FROM neobank.raw.transactions
                 WHERE account_id IN (SELECT account_id FROM neobank.raw.accounts WHERE customer_id = :p_customer_id);
                DELETE FROM neobank.raw.accounts  WHERE customer_id = :p_customer_id;
                DELETE FROM neobank.raw.consents  WHERE customer_id = :p_customer_id;
                DELETE FROM neobank.raw.customers WHERE customer_id = :p_customer_id;

                DELETE FROM neobank.governance.customer_identity WHERE customer_token = :v_token;
            END IF;
        END IF;
    END IF;

    INSERT INTO neobank.governance.erasure_log
        (request_id, customer_id_hash, requested_at, decided_at, decision, legal_basis, executed_by)
    SELECT :v_request_id, SHA2(:p_customer_id, 256),
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
           :v_decision, :v_basis, CURRENT_USER();

    COMMIT;
    RETURN v_request_id || ' ' || v_decision || ': ' || v_basis;

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;

USE ROLE SECURITYADMIN;
GRANT USAGE ON PROCEDURE neobank.governance.process_erasure_request(STRING) TO ROLE fr_privacy_officer;
GRANT SELECT ON TABLE neobank.governance.retention_rules TO ROLE ar_governance_read;


-- -----------------------------------------------------------------------------
-- 3. Demo: three requests, three outcomes
-- Test customers are picked by SYSADMIN (the privacy officer cannot read raw).
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;
SET active_customer = (SELECT MIN(customer_id) FROM neobank.raw.customers WHERE closed_at IS NULL);
SET recent_closed   = (SELECT MIN(customer_id) FROM neobank.raw.customers WHERE YEAR(closed_at) >= 2019);
SET old_closed      = (SELECT MIN(customer_id) FROM neobank.raw.customers WHERE YEAR(closed_at) <= 2017);

-- Before: the old customer has rows in raw, core and the vault.
SELECT 'before' AS moment,
       (SELECT COUNT(*) FROM neobank.raw.customers WHERE customer_id = $old_closed)            AS raw_rows,
       (SELECT COUNT(*) FROM neobank.governance.customer_identity WHERE customer_id = $old_closed) AS vault_rows;

USE SECONDARY ROLES NONE;
USE ROLE fr_privacy_officer;
CALL neobank.governance.process_erasure_request($active_customer);  -- expected RETAINED
CALL neobank.governance.process_erasure_request($recent_closed);    -- expected RESTRICTED
CALL neobank.governance.process_erasure_request($old_closed);       -- expected ERASED
CALL neobank.governance.process_erasure_request($old_closed);       -- again: NOT_FOUND

-- The log: decisions and legal basis, with a hash instead of the customer ID.
SELECT request_id, LEFT(customer_id_hash, 12) || '...' AS customer_id_hash, decision, legal_basis
FROM neobank.governance.erasure_log
ORDER BY requested_at DESC
LIMIT 4;

-- After: the erased customer is gone everywhere.
USE ROLE SYSADMIN;
SELECT 'after' AS moment,
       (SELECT COUNT(*) FROM neobank.raw.customers WHERE customer_id = $old_closed)            AS raw_rows,
       (SELECT COUNT(*) FROM neobank.governance.customer_identity WHERE customer_id = $old_closed) AS vault_rows;

USE SECONDARY ROLES ALL;

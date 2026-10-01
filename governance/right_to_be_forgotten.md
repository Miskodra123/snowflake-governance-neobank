# Right to be forgotten at a bank

How this project handles a GDPR Article 17 erasure request, and why it is not a simple `DELETE`.

## The problem

A customer asks the bank to delete their data. Three things make that hard:

1. **The law often says no, for now.** Article 17(3)(b) says the right to erasure does not apply while
   another law requires the bank to keep the data. For a German bank, anti-money-laundering law
   (GwG §8(4)) requires keeping identification and transaction records for 5 years, and commercial
   and tax law (§257 HGB, §147 AO) requires keeping booking vouchers for 8 years. Both periods start
   at the end of the year in which the customer relationship ended.
2. **Personal data is copied everywhere.** Landing tables, analytical tables, exports, backups and
   other systems all hold copies.
3. **Deleted is not gone straight away.** In Snowflake, deleted rows stay restorable for the Time
   Travel period, and then for 7 more days of Fail-safe.

## The pattern

```
raw (landing)            governance (identity vault)              core (analytics)
customer C0000123  ──►   token 7f3a… ↔ C0000123, name, email…  ──►  token 7f3a…, born 1987, DE
                                     │
                         erase = delete this row last
```

- Personal data is **pseudonymised at ingestion** (`sql/02_pseudonymisation.sql`). Real identifiers
  live in one place only: the identity vault. Everything else uses a token.
- The token is a **random UUID, not a hash** of the customer ID. Anyone who knows a customer ID could
  recompute a hash and re-link the data. A random token has no link to the person, so once the vault
  row is gone, the token points to nothing.
- One procedure, `governance.process_erasure_request` (`sql/08_erasure.sql`), handles every request.
  The privacy officer can run it but cannot run the deletes directly. It runs as one transaction and
  always writes the log.

## Four possible outcomes

| Situation | Decision | What happens | Legal basis |
|---|---|---|---|
| No vault record | `NOT_FOUND` | Nothing; logged | Unknown or already erased |
| Customer still active | `RETAINED` | Nothing; logged | Data needed for the contract, Art. 6(1)(b) |
| Closed, inside retention period | `RESTRICTED` | Email, phone and consents erased now. The rest is kept, restricted, until the period ends | Art. 17(3)(b) and Art. 18 |
| Closed, retention ended | `ERASED` | All rows deleted from core and raw, then the vault row last | Art. 17(1) |

Retention periods are kept in a table (`governance.retention_rules`), not in code, so Legal can change
them without a code change.

## Where the data still exists after erasure

| Zone | Time Travel | Fail-safe | Erased data fully gone after |
|---|---|---|---|
| raw (transient) | 1 day | none | 1 day |
| governance (vault) | 1 day | 7 days | 8 days, reachable only by Snowflake support after day 1 |
| core | 7 days | 7 days | 14 days, but pseudonymised and unlinkable once the vault row is gone |

All of this is well inside the one-month deadline for answering a request (Art. 12(3)). The retention
settings are chosen per zone on purpose (`sql/00_setup.sql`).

## Across connected systems

- **Re-loading from the source.** The erasure log stores a SHA-256 hash of the customer ID. The
  pseudonymisation step checks it, so an erased customer never gets a new token, even if the source
  system sends their data again.
- **Systems that only hold the token** (exports, a marketing tool, a data science sandbox) lose the
  link automatically when the vault row is deleted. This is the main reason to pseudonymise early.
- **Systems that hold real identifiers** (the core banking system itself) must be told to erase.
  The erasure log is the list of what to send. Notifying them is outside this demo.

## Proof

- `governance.erasure_log`: every request, decision, legal basis and who ran it. No customer IDs.
- `sql/09_audit_queries.sql` Q6: for every `ERASED` request, zero rows left in raw and in the vault.
- `sql/09_audit_queries.sql` Q7: customers whose retention has ended but who are still stored. Storage
  limitation (Art. 5(1)(e)) means the bank must delete them without waiting for a request.
- `sql/09_audit_queries.sql` Q8: re-identification risk in the pseudonymised data. With birth year and
  country, 16 customers sit in groups smaller than five. Adding the onboarding month makes almost
  every customer unique, which is why pseudonymised data is still personal data (Recital 26).

## Limits of this demo

- The longest retention period is applied to the whole customer record. A real bank sets periods per
  data category, confirmed by Legal.
- The retention periods are summarised from the laws named above and must be confirmed by Legal
  before use.
- Notifying source and downstream systems is described, not built.
- Restricted customers' remaining data is protected by the vault's access controls. A dedicated
  "restricted" flag in core, hidden by a policy, would be the next step.

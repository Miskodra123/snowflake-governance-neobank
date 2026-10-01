# Snowflake governance for a neobank

Data governance as code for a fictional neobank on Snowflake: who can see personal data, how it is
deleted on request, and how critical numbers are checked.

> **Status: in progress.** The table below shows what is built and what is planned. Nothing is marked
> as done until it runs in Snowflake.

## Why

A bank has to be able to prove three things about its data:

1. **Only the right people see personal data**, and there is a record of who looked at what.
2. **A customer can be forgotten** (GDPR Article 17), except where the law requires the bank to keep
   records, for example for anti-money-laundering checks.
3. **Its critical numbers can be trusted**: each one has an owner, a definition and automated quality
   checks (the BCBS 239 principles for risk data).

This project builds those controls in Snowflake as version-controlled SQL and YAML files, not as manual
settings in a user interface. The same scripts can be reviewed, rerun and audited.

## What it shows

| Governance need | How it is solved | File | Status |
|---|---|---|---|
| Separate zones with the right retention | Transient raw zone, managed-access core and governance zones | `sql/00_setup.sql` | done |
| Realistic test data, with known defects | Synthetic customers, accounts, transactions and consents | `sql/01_synthetic_data.sql` | done |
| Personal data not spread across tables | Pseudonymisation at ingestion, with a separate mapping table | `sql/02_pseudonymisation.sql` | done |
| Access by job, not by person | Role hierarchy: access roles and functional roles | `sql/03_roles.sql` | done |
| Know where personal data sits | Object tags and automatic classification of PII | `sql/04_classification.sql` | done |
| Only authorised roles see PII | Tag-based masking policies | `sql/05_masking.sql` | done |
| Staff see only their own entity's data | Row access policies by legal entity and country | `sql/06_row_access.sql` | planned |
| Critical data is checked automatically | Data metric functions on Critical Data Elements | `sql/07_data_quality.sql` | planned |
| Right to be forgotten | Erasure procedure on the mapping table | `sql/08_erasure.sql` | planned |
| Evidence for auditors | Queries on access history and on who can see PII | `sql/09_audit_queries.sql` | planned |
| Critical Data Elements have owners and rules | CDE register and ownership file | `governance/*.yml` | planned |
| Producers and consumers agree on the data | Data contracts in YAML | `governance/data_contracts/` | planned |

## Architecture

Three zones (schemas) in one database:

- **raw**: data as it lands. Short retention, so deleted personal data does not linger.
- **core**: cleaned, pseudonymised tables that analysts use. Customer identifiers are replaced by tokens.
- **governance**: the mapping table (token to real identifier), tags, policies and the CDE register.
  Only a small number of roles can read it.

A diagram will be added in a later phase.

## Repository structure

```
sql/                 Snowflake scripts, run in numbered order
governance/          CDE register, ownership, data contracts, right-to-be-forgotten write-up
docs/screenshots/    Evidence that the controls work
```

## How to run it

Requirements: a Snowflake account on **Enterprise edition** (a free trial works), because masking,
row access policies, tags and access history are Enterprise features.

Run the scripts in `sql/` in numbered order in a Snowflake worksheet. Details will be added as each
script is written.

## Key design decisions

These are the choices the scripts are built around. Each one is marked as done once its script is built.

- **Raw zone is transient.** Transient tables have no Fail-safe period, so personal data deleted from
  raw is gone within a day instead of being kept 7 more days. Raw data can be reloaded from the source,
  so losing Fail-safe there is acceptable.
- **Core and governance zones use managed access.** Only the schema owner can grant access, not whoever
  created a table. Access is controlled in one place.
- **Pseudonymise at ingestion.** Real identifiers live only in the mapping table. Deleting a customer's
  row there breaks the link to everything else. Pseudonymised data still counts as personal data under
  GDPR, so the remaining fields are checked for re-identification risk.
- **Erasure can yield to retention.** A bank must keep some records by law. The erasure procedure
  checks for that before deleting.

## Data

All data is synthetic and generated inside Snowflake. There is no real customer data in this project.
Some defects are added on purpose (for example missing emails and negative amounts) so the quality
checks have something to find.

## Roadmap

1. **Governance core** in Snowflake SQL and YAML (this phase).
2. **dbt layer**: models with enforced contracts, and tags and masking applied from configuration.
3. **CI/CD**: automated SQL linting and dbt checks in GitHub Actions, and a map from regulations
   (GDPR, BCBS 239, DORA) to the controls in this repo.

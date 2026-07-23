# Handoff: Importing bank-fetch transactions into Sure

**Status:** ready to run — blocked only on Sure being set up (URL, API key, account UUIDs).
**Owner after handoff:** Hermes.

## Goal

Get bank-fetch output (e.g. the DSB scrape, `dsb/output/dsb_*.json`) into a Sure
instance as transactions, idempotently (safe to re-run, no duplicates).

## Decision (why there's no big Sure code change)

The original spec (`spec/requests/api/v1/imports_api_spec.md` in the sure fork)
proposed building out the full `TransactionImport` CSV lifecycle on the API
(`update`/`clean`/`publish`/`revert`/`destroy`). We reviewed it against the repo
and chose **not** to build that, because Sure already exposes everything needed:

- `POST /api/v1/transactions` creates one transaction per call and is
  **idempotent** on `(account_id, source, external_id)`. Re-posting the same
  `external_id`+`source` returns the existing entry instead of duplicating.
- That endpoint reads `account_id`, `external_id`, and `source` from **inside**
  the `transaction` object (via `params.dig(:transaction, …)`), not top-level.
- Category resolution uses `GET /api/v1/categories` (existing categories only).

The spec also had concrete problems (references `@import.stats` /
`mappings_count` / `unassigned_mappings_count` which don't exist → would raise
`NoMethodError`; claims a migration is needed that already landed; uses
RSpec/FactoryBot which violates this repo's Minitest-only convention). It's kept
in the PR as reference/context, **not** as an approved implementation plan.

## The tool

`sure_publish.py` (in the **bank-fetch** repo, alongside this file). Pure Python
+ `requests`. Reads any bank-fetch `transactions_by_account` JSON and POSTs each
transaction to Sure. Nothing is hardcoded to DSB.

What it handles for you:

- **Sign convention (smart).** Sure uses "outflow positive, inflow negative" —
  the opposite of most bank statements. The script classifies each txn as
  inflow/outflow and sends `nature` + the absolute amount, letting Sure apply
  its own sign (so we never have to know Sure's internal rule). Direction comes
  from `--amount-convention`, default `auto`, which **verifies the sign against
  `running_balance` movement per account** and falls back to
  `negative_is_outflow` when the balance data is unreliable. On the DSB file it
  auto-detects `negative_is_outflow` correctly.
- **Dedup.** `external_id` = `transaction_number`, namespaced by `source`. Rows
  with no `transaction_number` get a stable content hash so they still dedup.
- **Description → name + notes.** Splits the ` / `-delimited description; the
  first non-empty segment is the clean `name`, the rest become `notes`. Disable
  with `--no-parse-description`; or pull notes from a raw field with
  `--notes-field`.
- **Category mapping (never creates categories).** `--category-rules @file.json`
  is an ordered keyword/regex list matched against the description; first match
  wins. Rule category names resolve against the family's **existing** categories
  only. Unknown name or no match → **no category** (nil). It cannot create
  categories.

## Prerequisites (the "set up Sure correctly" part)

1. **Sure base URL** → `SURE_BASE_URL` (e.g. `https://sure.example.com`).
2. **API key with `write` scope** → `SURE_API_KEY`. (For category mapping it also
   needs `read` to list categories.)
3. **Account UUID(s).** Map each bank-fetch account name to its Sure account id.
   Get ids from `GET /api/v1/accounts`. Example map: `{"SRD Checking":"<uuid>"}`.
4. **(Optional) Category rules file.** Only reference categories that already
   exist in Sure.

## Run it

Dry-run first (offline, no HTTP, prints exactly what would be sent):

```bash
python3 sure_publish.py \
  --input dsb/output/dsb_2026-07-22.json \
  --account-map '{"SRD Checking": "<real-sure-account-uuid>"}' \
  --dry-run
```

Then the real run:

```bash
export SURE_BASE_URL=https://sure.example.com
export SURE_API_KEY=sk_...
python3 sure_publish.py \
  --input dsb/output/dsb_2026-07-22.json \
  --account-map '{"SRD Checking": "<real-sure-account-uuid>"}' \
  --source dsb \
  --category-rules @category_rules.json      # optional
```

Example `category_rules.json` (categories must already exist in Sure):

```json
[
  {"match": "POS TRANSACTION", "category": "Groceries"},
  {"match": "SERVICE CHG",     "category": "Bank Fees"},
  {"match": "OD CHG",          "category": "Bank Fees"},
  {"match": "^SALARY",         "category": "Income", "regex": true}
]
```

Useful flags: `--only-account NAME`, `--limit N` (test a few), `--default-currency`,
`--amount-convention {auto,negative_is_outflow,positive_is_outflow}`.

## Verify

- The script prints a summary: `created`, `existing` (idempotent hits),
  `skipped`, `failed`, and the first few failures. Non-zero exit on any failure.
- Re-running the same file should show everything as `existing` (0 created) —
  proof dedup works.
- Spot-check a handful in the Sure UI: amount sign (expense vs income),
  name/notes, and category.

## Caveats

- **Category preview needs creds.** A pure `--dry-run` with no URL/key can't
  resolve category ids (no API call), so categories only attach on a real run.
  The rule-matching logic itself is source-agnostic and unit-tested.
- **Sign auto-detect** relies on `running_balance`. If a future source omits it
  or reports it inconsistently, pass `--amount-convention` explicitly.
- **`source` namespace.** Defaults to the leading token of the JSON `source`
  field (`dsb-automated-…` → `dsb`). Keep it stable across runs or dedup breaks.
- The script lives in the **bank-fetch** repo (local, no GitHub remote). This
  handoff is mirrored into the sure fork PR so it's visible on GitHub.

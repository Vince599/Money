# LedgerCore CSV backup profile 2

Status: implemented for the current `LedgerBook`, `EntryDraft` and `LedgerSettings` models. Date: 2026-09-26.

`BackupCodec.encode` returns twelve named CSV byte buffers. `BackupCodec.decode` validates the complete set and returns a `LedgerBackupSnapshot`; it does not write to the database. The archive layer packages these files into one ZIP, and the repository commits the decoded book, draft and settings in one transaction.

New exports identify `profile=ledger-core-v2`, `backup_format_version=2.0` and `db_schema_version=2`. `complete=true` means **all fields in these implemented models**, including account presentation identifiers, deleted operations' consumed UUID markers, the unfinished draft and defaults. It does not claim support for roadmap entities such as investments, refunds, reimbursement, loans, subscriptions, import rules, NAS jobs or daily valuation drafts. Those entities are not yet present in this model. Adding persistent fields requires a new supported contract and tested migration; an unknown profile, format version, schema version, file or column is rejected, never silently discarded.

The decoder also accepts the exact legacy triplet `ledger-core-v1 / 1.0 / db1`. Its older `accounts.csv` has no institution, template or icon columns, so restored accounts receive `nil` for those three presentation fields. The next export always uses profile 2. Mixed contracts, such as a v1 manifest with a v2 table header or field dictionary, are rejected.

## Files and model coverage

Every file exists, including empty tables containing only their header. Column names and their exact order are defined by `BackupSchema` and exported as `schema_dictionary.csv`.

| File | Rows and columns |
|---|---|
| `accounts.csv` | Array order; `position,id,name,kind,nature,currency,opening_minor,opening_at_utc,opening_at_bits,included_in_summary,is_active,institution_id,template_id,icon_id`. The final three text fields are nullable stable catalog identifiers; unknown nonempty values are retained losslessly. |
| `subjects.csv` | Array order; `position,id,name,is_active` |
| `categories.csv` | Array order; `position,id,name,parent_id,direction,symbol,is_active` |
| `entries.csv` | Array order; `position,id,operation_id,kind,amount_minor,currency,account_id,destination_account_id,category_id,subject_id,occurred_at_utc,occurred_at_bits,created_at_utc,created_at_bits,title,note,version` |
| `adjustments.csv` | Array order; `position,id,operation_id,account_id,difference_minor,difference_currency,target_minor,target_currency,occurred_at_utc,occurred_at_bits,note` |
| `retired_operations.csv` | `operation_id`; sorted on export, restored as a set. Retains consumed command IDs only, without deleted event contents. |
| `draft.csv` | Zero or one row; `entry_id,operation_id,kind,amount_text,account_id,destination_account_id,subject_id,expense_category_id,income_category_id,occurred_at_utc,occurred_at_bits,title,note` |
| `settings.csv` | Exactly one row; `default_account_id,default_subject_id` |
| `manifest.csv` | Exactly one row; `profile,backup_format_version,db_schema_version,app_version,complete,created_at_utc,created_at_bits,file_count` |
| `schema_dictionary.csv` | One row for every column in all twelve files, including its own columns; `file,column,position,type,required,nullable,unit,precision,allowed_values,foreign_key,meaning` |
| `counts.csv` | Exactly one row per file, including itself and checksums; `file,row_count`. Counts exclude the header. |
| `checksums.csv` | Exactly one row for each of the other eleven files; `file,sha256`. Does not hash itself. |

`position` starts at zero and is contiguous in physical row order. Array order is preserved even when a category child occurs before its parent. ID lookups validate relationships independently of presentation order. The manifest's `app_version` comes from `CFBundleShortVersionString`, or `unbundled` when running outside an application bundle. It is informational, never a substitute for format/schema versions.

The schema dictionary is generated from the same versioned definitions used by the reader. The decoder requires the exact bytes for the manifest's supported contract; a supplied dictionary cannot loosen validation. Every column is required in the header; `nullable` separately controls whether its values may be null. Empty `unit`, `precision`, `allowed_values`, `foreign_key` or `meaning` cells in the dictionary mean that attribute is not applicable. They are empty text, not missing columns.

## Byte and field encoding

Files are UTF-8 without a BOM. Record separators are LF, including the final record; a CSV record may span several physical lines because quoted field contents preserve CR and LF. Header names appear once and in the defined order. Field quoting follows [RFC 4180 section 2](https://www.rfc-editor.org/rfc/rfc4180#section-2): commas, quotes and line breaks require surrounding double quotes; an embedded quote is doubled. This profile deliberately fixes LF records instead of RFC 4180's CRLF convention.

Encoding has two layers, in this order:

1. A null becomes the two bytes `\N` (one backslash followed by capital N). Every backslash in a non-null **text** value is doubled. Empty text remains empty.
2. Apply CSV quoting. Empty text is always written as `""`.

Decoding reverses the CSV layer first. If the entire unquoted field is exactly `\N`, it is null and is allowed only in a nullable column. Otherwise, text columns collapse paired backslashes; any unpaired backslash is invalid. Non-text columns are parsed by their own type and do not apply text unescaping. ASCII escape characters are handled as UTF-8 bytes so a following Unicode combining mark cannot prevent escaping. No trimming, Unicode normalization, formula-prefix insertion or spreadsheet type coercion occurs.

| Original value | CSV bytes for the field |
|---|---|
| null | `\N` |
| literal backslash + N | `\\N` |
| empty text | `""` |
| `a,b` | `"a,b"` |
| `a"b` | `"a""b"` |
| text beginning with `=` | Original text, without an added apostrophe |

These are exact recovery files. A separate spreadsheet-friendly export must handle spreadsheet formulas without altering this format's recovery semantics.

## Value rules

UUIDs are lowercase standard 36-character hyphenated strings. Booleans are exactly `true` or `false`. Stable enums are listed in the dictionary. Every monetary field is a base-10 signed Int64 in the associated currency's minor unit (1/100 for CNY, HKD and USD). Money never passes through floating point. Integers use canonical spelling: ASCII digits, an optional negative sign, no leading zeros except `0`, no `-0`, plus sign, whitespace, decimal point, exponent or thousands separators. Posted amounts and versions must be positive; all arithmetic and currency constraints are checked by `LedgerEngine.validate`.

Each `Date` is represented by a pair:

- `*_utc`: `YYYY-MM-DDTHH:mm:ssZ`, the Gregorian UTC instant rounded **down** to a whole second for readable inspection.
- `*_bits`: exactly sixteen lowercase hex digits containing the IEEE 754 binary64 bit pattern of `Date.timeIntervalSinceReferenceDate`, in seconds relative to `2001-01-01T00:00:00Z`. This column preserves the actual stored `Date`, including subsecond precision, without decimal formatting loss. It does not encode money.

The reader reconstructs the exact date from the bits and verifies that its readable UTC companion matches. NaN, infinities and dates outside `0001-01-01T00:00:00Z <= date < 10000-01-01T00:00:00Z` are rejected before date formatting or calendar operations. There is no leap-second representation. Current models have no market-date, timezone or user-input `datePrecision` field; the UTC display column makes no assertion that a real transaction time was known to second precision. A future model that records that distinction must persist it under its own versioned contract.

## Validation and restoration

The decoder validates the filename set and size limits, then checks SHA-256 over the **original uncompressed bytes** of every protected file, before decoding those files. Headers, escaping and the final LF are part of the digest. It next selects one of the exact supported manifest triplets, verifies that contract's table headers and schema dictionary, then validates row counts, canonical scalar values, sequence positions and singleton counts, builds the model, and calls `LedgerEngine.validate`. Duplicate IDs, reused operation IDs, operation IDs present in both retired and live events, broken posted-event/category references, invalid money or overflowing balances fail restoration.

Settings must reference an existing active default subject and, when non-null, an existing active default account. An unfinished draft remains an unfinished draft: empty/invalid amount text and missing or inactive selections are retained for repair when reopened. Draft references are marked `soft:` in the dictionary. This is consistent with the store's draft contract and does not relax posted-event or settings references. Draft IDs/enums still have strict syntax; its date must be finite and within range. Both category selections are saved, even when the current draft type is transfer. A zero-row draft table means no draft; a one-row empty draft remains distinct.

`BackupError` exposes stable cases `unsupportedFormat(profile:version:)`, `invalidArchive(reason:)` and `invalidSnapshot(reason:)`. Reasons are English diagnostics; the UI supplies localized messages. Unsupported source database schema versions use `version="<format>;db=<schema>"`. The codec has no side effects, so a decoding failure cannot alter a current book; the integration layer must also commit successful restore results atomically.

The portable SHA-256 implementation follows [RFC 6234 sections 4–6](https://www.rfc-editor.org/rfc/rfc6234#section-4). Its tests check the empty string, `abc`, the standard 56-byte message and one million `a` bytes. Hashes detect accidental corruption; they are **not authentication**, because someone able to modify all files can also recompute the unkeyed hashes.

## Current resource limits and verification

The in-memory codec accepts at most 64 MiB of total CSV bytes, 32 MiB for an individual CSV, 100,000 data records per file, 64 columns per record and 1 MiB per field after CSV unquoting but before text backslash unescaping. The writer applies the same limits. They bound malformed input and are not a claim that a 100,000-transaction end-to-end workload has been performance-qualified. Streaming and large-scale database optimization remain separate work.

`BackupCodecTests` covers full-model round trips, exact Int64 bounds and Date bits, array order, inactive historical accounts, default settings, retired commands, absent/unfinished/unresolved drafts, Unicode combining text, embedded CR/LF/quotes, null-versus-empty, hash coverage, future versions, schema changes, invalid scalars, duplicate identities, broken references and parser limits. `BackupSHA256Tests` validates the standard algorithm vectors. Windows can run the pure core tests. Database and repository restoration integration has passed the macOS store tests and iOS simulator App tests.

On 2026-09-26, the user reported that an earlier build exported a ZIP through the system Files app and restored its balances and entries on an iOS 27 device. This is user-reported evidence for that earlier build, not a physical-device validation of the third batch. Physical-device restoration of the third batch's calculator-expression and copied-entry drafts remains pending; detailed evidence and limitations are recorded in [DEVELOPMENT.md](DEVELOPMENT.md).

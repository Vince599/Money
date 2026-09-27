# LedgerCore CSV backup profile 9

Status: implemented for the current `LedgerBook`, `EntryDraft` and `LedgerSettings` models. Date: 2026-09-27. Current platform verification is recorded in [DEVELOPMENT.md](DEVELOPMENT.md).

`BackupCodec.encode` returns twenty-three named CSV byte buffers. `BackupCodec.decode` validates the complete set and returns a `LedgerBackupSnapshot`; it does not write to the database. The archive layer packages these files into one ZIP, and the repository commits the decoded book, draft and settings in one transaction.

New exports identify `profile=ledger-core-v9`, `backup_format_version=9.0` and `db_schema_version=9`. `complete=true` means **all fields in these implemented models**, including versioned import rules with conditions and actions, import batches, raw source fields, per-row mapping/completion/review/reversal state and batch reversal time, import-row ordered tags and project selections, staged accounts, tags, projects, ordered entry/draft tag links, account presentation identifiers, refund/recovery links, purchase-level net recovery opt-in, deleted operations' consumed UUID markers, the unfinished draft and defaults. It does not claim support for roadmap entities such as investments, reimbursement, loans, subscriptions, NAS jobs or daily valuation drafts. Those entities are not yet present in this model. Adding persistent fields requires a new supported contract and tested migration; an unknown profile, format version, schema version, file or column is rejected, never silently discarded.

The decoder also accepts the exact legacy triplets `ledger-core-v1 / 1.0 / db1`, `ledger-core-v2 / 2.0 / db2`, `ledger-core-v3 / 3.0 / db3`, `ledger-core-v4 / 4.0 / db4`, `ledger-core-v5 / 5.0 / db5`, `ledger-core-v6 / 6.0 / db6`, `ledger-core-v7 / 7.0 / db7` and `ledger-core-v8 / 8.0 / db8`. Version 1's `accounts.csv` has no institution, template or icon columns, so restored accounts receive `nil` for those three presentation fields. Profiles 1 and 2 lack recovery links and opt-in fields; these decode as `nil`, with net recovery disabled. Profiles 1 through 3 lack tags, projects and their associations; these restore as empty arrays / nil. Profile 3 keeps its recovery fields. Profile 4 keeps tags and projects. Profiles 1–4 restore with empty import batches. Profile 5 retains import state with empty row tags and nil row projects. Profiles 5 and 6 restore with nil reversal time; profile 6 retains import-row labels. Profiles 1–7 restore with empty import rules; profile 7 retains reversal state. Profile 8 retains its account/category/subject rule actions. The next export always uses profile 9. Mixed manifests, table headers and field dictionaries are rejected.

## Files and model coverage

Every file exists, including empty tables containing only their header. Column names and their exact order are defined by `BackupSchema` and exported as `schema_dictionary.csv`.

| File | Rows and columns |
|---|---|
| `accounts.csv` | Array order; `position,id,name,kind,nature,currency,opening_minor,opening_at_utc,opening_at_bits,included_in_summary,is_active,institution_id,template_id,icon_id`. The final three text fields are nullable stable catalog identifiers; unknown nonempty values are retained losslessly. |
| `subjects.csv` | Array order; `position,id,name,is_active` |
| `categories.csv` | Array order; `position,id,name,parent_id,direction,symbol,is_active` |
| `entries.csv` | Array order; `position,id,operation_id,kind,amount_minor,currency,account_id,destination_account_id,category_id,subject_id,occurred_at_utc,occurred_at_bits,created_at_utc,created_at_bits,title,note,version,original_entry_id,allows_net_recovery,project_id` |
| `adjustments.csv` | Array order; `position,id,operation_id,account_id,difference_minor,difference_currency,target_minor,target_currency,occurred_at_utc,occurred_at_bits,note` |
| `retired_operations.csv` | `operation_id`; sorted on export, restored as a set. Retains consumed command IDs only, without deleted event contents. |
| `draft.csv` | Zero or one row; `entry_id,operation_id,kind,amount_text,account_id,destination_account_id,subject_id,expense_category_id,income_category_id,occurred_at_utc,occurred_at_bits,title,note,original_entry_id,allows_net_recovery,project_id` |
| `tags.csv` | Array order; `position,id,name,is_active` |
| `projects.csv` | Array order; `position,id,name,is_archived` |
| `entry_tags.csv` | `position,entry_id,tag_id`; export groups by entry array order, preserving each entry tag order. Both references must exist; duplicate pairs are rejected. |
| `draft_tags.csv` | `position,entry_id,tag_id`; preserves draft tag order. Entry ID must match the single draft; tag IDs are soft references and may be unavailable. Duplicate pairs are rejected. |
| `import_batches.csv` | Array order; `position,id,name,namespace,version,created_at_utc,created_at_bits,reverted_at_utc,reverted_at_bits`. The two reversal columns are both null or form one matching date pair. |
| `import_rows.csv` | Global contiguous order; `position,batch_id,id,operation_id,account_id,destination_account_id,category_id,subject_id,state,duplicate_review_token`, followed by `raw_source_id,raw_occurred_at,raw_type,raw_amount,raw_currency,raw_account,raw_destination_account,raw_category,raw_title,raw_note,raw_status`, then nullable `project_id`. Raw fields are text, including amount and source IDs. States are `pending`, `imported`, `skipped`, `reverted`. Reverted rows require a closed batch, a retired operation ID and absence of the original event. Mapping references stay soft; imported operation IDs must be consumed and any live matching operation must belong to this row ID. |
| `import_row_tags.csv` | `position,row_id,tag_id`; contiguous global order preserves each import row’s tag order. Row ID must exist; tag references are soft so unavailable selections survive for repair. Duplicate pairs are rejected. |
| `import_accounts.csv` | `batch_id` followed by all `accounts.csv` columns. Position is global across this table; account array order within each batch is retained. These are staged accounts, not formal balances. |
| `import_rules.csv` | `position,id,name,namespace,priority,is_enabled,version,currency,minimum_minor,maximum_minor`. Namespace, currency and bounds are nullable. Bounds are inclusive integer minor units and require currency; priority is 0–10000, lower wins. |
| `import_rule_conditions.csv` | `position,rule_id,field,comparison,value`. Ordered AND conditions; field is `title|note|category|account|kind`, comparison `equals|contains`. Kind requires exact `expense|income|transfer`. Rule reference is hard. |
| `import_rule_actions.csv` | `position,rule_id,field,target_id`. Field is `account|destinationAccount|category|subject|tag|project`, unique per rule. Tag means append one tag, preserving existing order without duplicates; project means set one project; destinationAccount applies only to transfers. Rule reference is hard; target is a soft typed reference to the corresponding catalog, preserving unavailable targets for repair. |
| `settings.csv` | Exactly one row; `default_account_id,default_subject_id` |
| `manifest.csv` | Exactly one row; `profile,backup_format_version,db_schema_version,app_version,complete,created_at_utc,created_at_bits,file_count` |
| `schema_dictionary.csv` | One row for every column in all twenty-three files, including its own columns; `file,column,position,type,required,nullable,unit,precision,allowed_values,foreign_key,meaning` |
| `counts.csv` | Exactly one row per file, including itself and checksums; `file,row_count`. Counts exclude the header. |
| `checksums.csv` | Exactly one row for each of the other twenty-two files; `file,sha256`. Does not hash itself. |

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

Entry `kind` supports `expense|income|transfer|refund|recovery`. A posted refund/recovery must reference one expense through `original_entry_id`, use the original currency and subject, and occur no earlier than the purchase; it has no category or transfer destination. The receiving account may differ. Other kinds require a null original reference. Only an expense may have a non-null `allows_net_recovery`; null/false disables cumulative recovery above its original amount. Enabling this purchase-level option permits a negative net cost, displayed as net recovery, without changing income or budget occupancy. The entire receipt belongs to its one original purchase; no amount is posted twice. Category directions remain `expense|income`.

The previous SQLite schema 3 added the two nullable entry projections and a deferred self-reference with no cascading deletion. Versions 1 and 2 migrate in the same transaction as opening validation; existing payload bytes remain intact. Derived recovery totals and deletion previews are recomputed, not backed up as authoritative balances. Group deletion retires every removed operation ID; unfinished drafts retain soft references for user repair.

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

## Tags and projects in schema 4

Schema 4 adds the tag/project catalogs, the entry-tag relation table and nullable `project_id`. Existing schema 1/2/3 databases migrate atomically without rewriting payloads; missing arrays in older JSON decode as empty. Opening validation failure rolls back the DDL and version. Inactive tags and archived projects remain valid in historical records and restore, while posting commands reject newly selected unavailable references. Draft references stay soft. The existing 100,000-row limit applies independently to link tables as well; a multi-tag entry consumes more than one link row. See [TAGS_PROJECTS.md](TAGS_PROJECTS.md) for implementation and verification boundaries.

## Import state in schema 5

Schema 5 adds the import batch table with checked scalar projections and complete Codable payloads. Migration and opening validation share a transaction; earlier payloads remain untouched. Profile 5 flattens every raw source column, mapping, completion state and staged account into explicit CSV tables. Orphan rows/accounts, invalid imported receipts and duplicate source identities are rejected; pending rows may retain unavailable mappings for repair. See [IMPORT.md](IMPORT.md) for the separate public import CSV format, limits and validation scope.

## Profile 6 and schema 6

Profile 6 adds `import_row_tags.csv` and the final nullable `project_id` column to `import_rows.csv`; all twenty files, headers and the exact dictionary are required. Profile 5's nineteen-file dictionary and row header are frozen separately. Empty and unavailable draft references are preserved without converting draft rows into cash events. Duplicate links and orphan row IDs are rejected even with valid hashes.

Schema 6 stores the new fields inside existing `import_batches.payload`. Opening schema 5 advances the version inside the same validation transaction without rewriting payload bytes; absent fields decode as an empty tag array / nil project. Invalid payloads roll back the version change. Schema 1–4 migrations still create missing tables before the same final validation. Apple GRDB migration tests are present but pending execution; Core JSON and CSV compatibility tests passed locally.

## Profile 7 and schema 7

Profile 7 retains twenty files and adds a paired nullable reversal date to `import_batches.csv`, plus the `reverted` value to `import_rows.csv.state`. The exact profile 6 batch header and enum dictionary remain frozen; profile 5 uses the same legacy batch header and its own row header. Both nullable date columns must be present in profile 7's header and either both null or agree exactly. Schema 7 persists the optional date in the existing batch payload; schema 5 and 6 migrate without payload rewrites inside the open-and-validate transaction.

This is reversal of unchanged ordinary imported events. The immutable completed row's source fields, mappings, IDs, labels and batch creation date reconstruct its original version-1 event and remain backed up after reversal. It does not represent a general trash bin, removal of accounts/opening balances, or a merge-history snapshot. Future merge support must introduce its own complete before-state contract. Reversed batches remain closed and their consumed operation IDs cannot be replayed; explicitly creating a fresh import batch can use the released external source identity with new internal IDs.

## Profile 8 and schema 8

Profile 8 adds three explicit rule tables for twenty-three files. Rule names, scope, priorities, enabled flags, versions, currency/bounds, ordered conditions and actions survive round trips; no JSON cells hide these fields. Conditions are ANDed, with at least one textual condition or amount bound and one action. Missing/inactive action targets pause suggestions without deleting their configuration; an enabled-but-unavailable restored rule is shown as paused. Editing such a rule requires repairing its targets or disabling it before save. Orphan conditions/actions, duplicate action fields, invalid amount ranges and unsupported enums are rejected even after hashes are recomputed. All profile 1–7 contracts remain frozen.

SQLite schema 8 adds `import_rules`, validates scalar projections against its Codable payload, and migrates schemas 1–7 inside the open-and-validate transaction. Existing business payload bytes stay intact. Migration failure rolls back the new table and schema version. Rule changes and explicitly confirmed row mapping changes use whole-book transactions while preserving the latest manual draft and settings; no cash event is created by applying a rule.

## Profile 9 and schema 9

Profile 9 retains twenty-three files and expands the action enum and typed soft-reference dictionary for transfer destination accounts, appended tags and projects. Each rule has at most one action for each of the six fields. Tags are additive: no automatic replacement, clearing or union of conflicting rule suggestions. Applying a rule only modifies reviewed pending mappings; ordinary posting still validates the resulting transaction. Destination and source accounts must differ when either account field is applied to a transfer.

Profile 8's dictionary and original three action enum values are frozen separately; new action enum values in a v8 archive are rejected even with recomputed checksums. Old rules restore unchanged. Missing/inactive tags or archived projects retain their IDs and pause suggestions for repair. SQLite schema 9 uses the existing rule payload without new SQL columns; the 8-to-9 migration preserves bytes and rolls back its version on failed full validation. These Apple-side migration tests are written but await execution.

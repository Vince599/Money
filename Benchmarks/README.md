# LedgerCore function baseline

This tool measures the current pure Swift Core in a separate **Release** package. It reads no user book or backup. Each run snapshots the actual `Sources/LedgerCore` files and the benchmark driver into its own ignored `build/performance/<run>/package` directory; the root package and Apple dependency lock remain untouched.

```powershell
# Small smoke run: build and check the tool before a full baseline.
./scripts/benchmark-core.ps1 -Sizes 0,1200 -Samples 2 -Warmups 1

# Default baseline: 0 / 10,000 / 100,000 entries, ten measured samples plus one warmup.
./scripts/benchmark-core.ps1

# More repetitions, if the host is otherwise quiet.
./scripts/benchmark-core.ps1 -Sizes 10000,100000 -Samples 30 -Warmups 2
```

The fixed `core-mixed-v1` fixture has six accounts, two subjects, CNY/HKD/USD, expenses/incomes/same-currency transfers, four years of dates, Chinese/English text and long notes. IDs, dates and amounts do not depend on the machine clock or randomness. Fixture creation, full initial validation and independently computed expected results are outside the timed region. Each record attempt starts from the same original book and adds the same new entry; attempts never accumulate into a growing book.

Four operations are measured separately:

- `validate`: full `LedgerEngine.validate`.
- `recordExpense`: `LedgerEngine.record`, including its own validations and in-memory copying.
- `queryAll`: `EntryQuery.entries` with no filters, returning every row in its sorted order.
- `queryCombined`: the same query with a fixed keyword, kind, account, parent category, subject, currency, amount range and date interval.

The report stores every warmup and measured attempt, nanoseconds from `ContinuousClock`, outcome, per-operation p50/p95/maximum in milliseconds, fixture version, source-file hashes, the combined compiled-source hash, compiler/platform and Release configuration. Percentiles use nearest rank; with fewer than 20 samples, p95 will usually be the maximum. Warmups are retained but excluded from those summaries. No measured outlier is dropped. A correctness failure preserves the partial report and exits unsuccessfully; incomplete/failed summaries are not usable performance results.

Checks run after timing: record count, new identity and resulting balance; complete query result IDs and ordering. These checks can warm caches between samples. This is a resident-memory baseline, not a cold-cache experiment. Build time, fixture generation, report serialization and correctness checks are excluded; memory, energy and user-perceived latency are not measured. Runs do not control other host processes, thermal state or power mode. Compare only like-for-like fixture versions, inputs, compiler, configuration and host conditions, retaining all raw files.

**No result from this tool proves SQLite, SwiftUI, iPhone speed, or Q01–Q09 acceptance.** In particular, queries return full arrays and do not measure database pagination, rendering or debounce; recording does not persist a transaction. Apple type-checking and Release device measurements remain separate. Do not turn these machine-dependent timings into fixed unit-test pass/fail limits.

Only `results.json`, `metadata.json` and `run.log` need to be kept for comparison; the package directory is the exact reproducible source snapshot for that run. The script deliberately does not delete prior runs or benchmark packages.

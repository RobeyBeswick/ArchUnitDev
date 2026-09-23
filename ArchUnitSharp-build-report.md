# ArchUnitSharp — full build cost & token report

> Generated from the ArchUnitDev harness logs (local `logs/` + S3 bucket `archunitdev-logs-…/loop/20260831T214650Z/`) and GitHub issue/commit metadata. Raw data captured at model-invocation granularity.

## 1. Scope and methodology

- **Target:** [`RobeyBeswick/ArchUnitSharp`](https://github.com/RobeyBeswick/ArchUnitSharp) — architecture testing library for C#/.NET, built issue-by-issue by the ArchUnitDev loop.
- **Model:** `opencode-go/deepseek-v4-flash` for implement, all three critics, fix and retro; `VARIANT=high`. (No model split — one model for everything.)
- **Loop mechanics per issue:** implement → deterministic gate (`gate/csharp.sh`: `dotnet build` + `dotnet test`) → up to 3 parallel critics (review / tests / idiom) → fix round; up to 3 fix rounds, then abandon-and-retry on a later batch.
- **Date range:** 2026-08-25 (issue #1) → 2026-09-01 (issue #46). All 46 issues tracked; #44 (`Publish to NuGet`) intentionally skipped (needs NuGet credentials, not the loop).
- **Cost granularity:** every model invocation has a `total_cost_usd` (sum of per-step `step_finish.cost`). Every step's token counts (`input`, `output`, `reasoning`, `cache.read`, `cache.write`) are recorded in the raw `.jsonl`.
- **Currency:** USD. **Model spend only** in the headline; AWS infrastructure cost is itemised in §6.

## 2. Grand totals

| Metric | Value |
|---|---:|
| Issues landed (closed on GitHub) | 45 of 46 |
| Issues skipped by hand | 1 (#44 NuGet) |
| Total model spend (all invocations) | **$19.8640** |
|  — local (issues 1–8 bring-up, incl. redundant issue-8 smoke) | $1.9958 |
|  — EC2 (issues 8–46, all attempts incl. overwritten re-attempts) | $17.8682 |
| Model invocations | 511 |
| Implement invocations (fresh attempts incl. retries) | 54 |
| Total model turns (assistant steps) | 7,183 \* |
| Tokens — input | 27,923,369 |
| Tokens — output | 9,738,714 |
| Tokens — reasoning | 1,425,257 |
| Tokens — cache read | 583,483,008 |
| Tokens — cache write | 0 |
| Total findings raised by critics | 127 |
| Critic verdicts — PASS / FAIL | 264 / 109 |

- Effective cost per landed issue: **$0.4414**
- Effective cost per model turn: **$0.002765**

> Note on cache-read tokens: `cache.read` (583.5M of the total) is the model re-reading the running conversation context on every step — billed at the provider's cache-discount rate, which is why it contributes so little to cost. Input/output/reasoning are the "new" tokens.

\* **Turns undercounts by the 27 lost issue-#27 invocations** (their `.json` files were overwritten; turn counts are not in the `run.log` ledger). Cost is not affected — it is recovered from the ledger. Tokens likewise cover only surviving files.

## 3. Per-issue table

| # | Issue | Status | $ cost | invocations | attempts¹ | rounds² | turns | input | output | reasoning | cache.read | findings | PASS/FAIL |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | Kernel: Edge, Graph and ImportKind | landed | $0.3227 | 26 | 2 | 4 | 196 | 472,406 | 276,821 | 0 | 5,156,352 | 10 | 10/10 |
| 2 | Kernel: pattern matching — globs, regex and match targets | landed | $0.1771 | 9 | 1 | 2 | 65 | 220,437 | 44,988 | 127,824 | 2,082,432 | 1 | 6/1 |
| 3 | Kernel: RegexFactory and the matcher factories | landed | $0.1133 | 5 | 1 | 1 | 46 | 274,507 | 47,361 | 19,485 | 1,249,408 | 0 | 4/0 |
| 4 | Kernel: Violation base type and EmptyTestViolation | landed | $0.1201 | 9 | 1 | 2 | 78 | 252,846 | 30,498 | 48,507 | 1,767,296 | 2 | 5/2 |
| 5 | Kernel: CheckOptions and the Checkable contract | landed | $0.1999 | 13 | 1 | 3 | 98 | 242,441 | 194,145 | 286 | 2,604,160 | 4 | 7/3 |
| 6 | Kernel: TechnicalError and UserError | landed | $0.0587 | 9 | 1 | 2 | 60 | 112,606 | 38,380 | 0 | 1,224,448 | 3 | 4/3 |
| 7 | Extraction: locate the project and enumerate source files | landed | $0.8483 | 31 | 3 | 4 | 293 | 1,137,384 | 558,823 | 212,898 | 12,683,520 | 13 | 12/11 |
| 8 | Extraction: parse imports and resolve them to targets | landed | $0.5086 | 22 | 2 | 3 | 232 | 892,366 | 220,456 | 136,427 | 10,957,184 | 4 | 13/4 |
| 9 | Extraction: classify internal vs external dependencies | landed | $0.1097 | 9 | 1 | 2 | 71 | 286,393 | 35,730 | 21,737 | 1,247,360 | 1 | 6/1 |
| 10 | Extraction: self-edges and parallel-edge merging | landed | $0.1011 | 5 | 1 | 1 | 56 | 238,536 | 38,329 | 14,176 | 1,999,232 | 0 | 4/0 |
| 11 | Extraction: graph cache and clear-graph-cache | landed | $0.2377 | 9 | 1 | 2 | 110 | 426,832 | 154,951 | 22,357 | 3,822,976 | 5 | 4/3 |
| 12 | Extraction: per-line ignore directive | landed | $0.2082 | 5 | 1 | 1 | 80 | 424,632 | 82,845 | 35,079 | 5,273,344 | 0 | 4/0 |
| 13 | Projection: project edges, nodes and cycles | landed | $0.3673 | 9 | 1 | 2 | 115 | 502,695 | 292,165 | 0 | 9,118,976 | 2 | 6/1 |
| 14 | Projection: the per-edge MapFunctions | landed | $0.0903 | 5 | 1 | 1 | 52 | 138,019 | 74,027 | 0 | 1,583,360 | 0 | 4/0 |
| 15 | Projection: cycle detection — Tarjan and Johnson | landed | $0.0743 | 5 | 1 | 1 | 50 | 121,367 | 58,013 | 0 | 1,326,080 | 0 | 4/0 |
| 16 | Files API: entry point and selectors | landed | $0.1964 | 5 | 1 | 1 | 91 | 233,877 | 140,615 | 0 | 7,454,720 | 0 | 4/0 |
| 17 | Files API: should and should not | landed | $0.2293 | 9 | 1 | 2 | 125 | 383,498 | 155,403 | 123 | 6,041,856 | 1 | 6/1 |
| 18 | Files API: have no cycles | landed | $0.2472 | 5 | 1 | 1 | 108 | 289,342 | 173,668 | 0 | 9,850,880 | 0 | 4/0 |
| 19 | Files API: have name, be in folder, be in path | landed | $0.1604 | 5 | 1 | 1 | 81 | 260,009 | 109,011 | 0 | 4,466,432 | 0 | 4/0 |
| 20 | Files API: depend on files | landed | $0.4638 | 13 | 1 | 3 | 189 | 651,858 | 337,088 | 0 | 13,981,440 | 5 | 6/4 |
| 21 | Files API: depend on external modules | landed | $0.2424 | 5 | 1 | 1 | 86 | 549,832 | 116,961 | 22 | 6,316,032 | 0 | 4/0 |
| 22 | Files API: adhere to — custom user predicate | landed | $0.2420 | 5 | 1 | 1 | 101 | 313,044 | 157,166 | 0 | 9,920,256 | 0 | 4/0 |
| 23 | The empty-test guard on every terminal | landed | $0.1793 | 9 | 1 | 2 | 121 | 278,273 | 113,103 | 0 | 6,207,744 | 1 | 6/1 |
| 24 | Testing: violation formatting, result shaping and colour | landed | $0.1861 | 5 | 1 | 1 | 103 | 276,480 | 117,739 | 0 | 6,796,032 | 0 | 4/0 |
| 25 | Testing: the framework-agnostic assert helper | landed | $0.1419 | 5 | 1 | 1 | 78 | 241,416 | 85,461 | 0 | 4,626,944 | 0 | 4/0 |
| 26 | Testing: native integration with xUnit, with NUnit and MSTest covered by the agnostic path | landed | $0.4714 | 9 | 1 | 2 | 175 | 625,347 | 278,421 | 0 | 21,435,904 | 2 | 5/2 |
| 27 | Layers API | landed | $2.9458 | 17 | 1 | 4 | 233 | 1,145,408 | 79,736 | 358,217 | 19,506,944 | 6 | 7/6 |
| 28 | Graph reports: the snapshot and its query options | landed | $1.5213 | 34 | 2 | 4 | 550 | 2,223,736 | 1,049,171 | 0 | 48,517,376 | 13 | 14/12 |
| 29 | Graph reports: the six output formats | landed | $0.2924 | 5 | 1 | 1 | 128 | 326,153 | 187,055 | 0 | 13,890,816 | 0 | 4/0 |
| 30 | Slices API: slicing projections and forbidden dependencies | landed | $0.8393 | 9 | 1 | 2 | 246 | 1,444,097 | 407,061 | 131 | 36,124,416 | 5 | 4/3 |
| 31 | Slices API: PlantUML component diagrams | landed | $0.8136 | 13 | 1 | 3 | 265 | 1,364,218 | 439,286 | 0 | 31,939,584 | 6 | 5/5 |
| 32 | Metrics: extraction and count metrics | landed | $1.1169 | 17 | 1 | 4 | 339 | 1,574,165 | 648,383 | 0 | 48,956,928 | 9 | 8/5 |
| 33 | Metrics: the LCOM family | landed | $0.7776 | 17 | 1 | 4 | 274 | 1,238,793 | 482,720 | 0 | 26,642,688 | 7 | 8/5 |
| 34 | Metrics: distance metrics and the zone checks | landed | $0.8777 | 17 | 1 | 4 | 311 | 1,283,268 | 511,234 | 0 | 36,848,128 | 5 | 8/5 |
| 35 | Metrics: custom metrics | landed | $0.4778 | 13 | 1 | 3 | 193 | 885,093 | 273,042 | 0 | 14,695,424 | 2 | 8/2 |
| 36 | Metrics: threshold verbs | landed | $0.1784 | 9 | 1 | 2 | 100 | 337,625 | 110,708 | 0 | 4,443,136 | 1 | 6/1 |
| 37 | Metrics: HTML report export | landed | $0.3485 | 5 | 1 | 1 | 147 | 414,312 | 196,346 | 0 | 18,252,032 | 0 | 4/0 |
| 38 | Pattern exclusions — the `except` companion | landed | $0.5161 | 9 | 1 | 2 | 201 | 665,734 | 285,202 | 0 | 25,909,504 | 1 | 6/1 |
| 39 | Logging | landed | $0.8777 | 13 | 1 | 3 | 347 | 1,376,603 | 449,820 | 0 | 39,706,368 | 4 | 6/4 |
| 40 | Dogfood: enforce our own architecture rules on ourselves | landed | $0.6146 | 15 | 2 | 4 | 320 | 998,761 | 337,571 | 52,060 | 19,671,296 | 4 | 7/3 |
| 41 | README someone can actually start from | landed | $0.2767 | 9 | 1 | 2 | 134 | 554,754 | 142,023 | 0 | 8,700,160 | 2 | 5/2 |
| 42 | Documentation site on GitHub Pages | landed | $0.3212 | 9 | 1 | 2 | 157 | 698,187 | 71,063 | 39,700 | 13,496,704 | 1 | 6/1 |
| 43 | CI: build, test and lint on every push | landed | $0.3930 | 13 | 1 | 3 | 175 | 831,841 | 50,661 | 195,324 | 6,810,368 | 3 | 7/3 |
| 44 | Publish to NuGet | OPEN | — | — | — | — | — | — | — | — | — | — | — |
| 45 | Restore the full test suite to green across the CI matrix | landed | $0.2259 | 9 | 1 | 2 | 134 | 373,583 | 66,356 | 91,668 | 5,625,984 | 4 | 3/4 |
| 46 | Prevent Metrics<T>() from silently passing without analyzing the target type | landed | $0.1519 | 5 | 1 | 1 | 69 | 340,595 | 19,108 | 49,236 | 4,550,784 | 0 | 4/0 |

¹ attempts = number of `implement` invocations (a fresh implementation, including re-attempts after abandonment). ² rounds = highest fix round reached (1 = landed after the first implementation review cycle).

> **Cost vs token/round columns for re-attempted issues.** For issues #27, #28 and #40 the `$ cost` column is the **authoritative total across every attempt** (recovered from the `run.log` ledger — see §8), because earlier attempts' files were overwritten on S3. Their `invocations`, `attempts`, `rounds`, `turns` and token columns cover **only the surviving files** (the final attempt). For all other issues the two are identical.

## 4. Re-attempted / abandoned issues

The following issues were abandoned at least once (failed to reach a unanimous critic PASS within the round budget) and later re-attempted. The cost shown is the **total across all attempts** (the failed attempt(s) + the landing attempt).

| # | Issue | Abandonments | Notes | Total cost |
|---|---|:---:|---|---:|
| 1 | Kernel: Edge, Graph and ImportKind | 1 | abandoned locally 2026-08-25; landed 2026-08-25 | $0.3227 |
| 7 | Extraction: locate the project and enumerate source files | 2 | abandoned locally 2026-08-26 twice; landed 2026-08-26 | $0.8483 |
| 27 | Layers API | 3 | abandoned 2026-08-28 (3×); landed 2026-08-30 | $2.9458 |
| 28 | Graph reports: the snapshot and its query options | 1 | abandoned 2026-08-30; re-attempt landed same day | $1.5213 |
| 40 | Dogfood: enforce our own architecture rules on ourselves | 1 | abandoned 2026-09-01; re-attempt landed same day | $0.6146 |

Carryover files in the logs: `27-carryover.md`, `28-retry-carryover.md`, `40-retry-carryover.md` (outstanding findings fed into the re-attempt).

## 5. Per-invocation detail

Every model invocation across the whole build, in queue order (implement → fix → review → tests → idiom), keyed by `issue-role[-round][a/b]`. `retry` invocations are the re-attempt pass. Source `local` = this laptop's bring-up runs (run id = log dir); `ec2` = the EC2 host (run id `s3logs`, synced to S3).

> **Completeness:** this table lists only invocations whose files survive (the final attempt of each re-attempted issue). The 27 invocation files from issue #27's first three attempts are gone (overwritten on S3); their costs are included in the totals (§2/§3) via the `run.log` ledger but their per-step tokens are unrecoverable. In total 484 invocation rows are listed; the true invocation count (all attempts) is 511 (484 + 27).

| tag | run | role | round | retry | source | $ cost | turns | reason | verdict | findings | in | out | reas. | cache.r | cache.w |
|---|---|---|---|---|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|
| 1-implement | csharp1 | implement |  |  | local | $0.0283 | 30 | stop |  | 0 | 24,686 | 24,332 | 0 | 979,712 | 0 |
| 1-implement | csharp1b | implement |  |  | local | $0.0406 | 52 | stop |  | 0 | 34,729 | 29,200 | 0 | 1,957,632 | 0 |
| 1-fix-1 | csharp1 | fix | 1 |  | local | $0.0136 | 16 | stop |  | 0 | 20,517 | 10,291 | 0 | 331,520 | 0 |
| 1-fix-1 | csharp1b | fix | 1 |  | local | $0.0127 | 13 | stop |  | 0 | 20,505 | 9,518 | 0 | 274,176 | 0 |
| 1-fix-2 | csharp1 | fix | 2 |  | local | $0.0201 | 16 | stop |  | 0 | 34,148 | 13,517 | 0 | 529,920 | 0 |
| 1-fix-3 | csharp1 | fix | 3 |  | local | $0.0081 | 12 | stop |  | 0 | 12,836 | 5,314 | 0 | 257,536 | 0 |
| 1-review-1 | csharp1 | review | 1 |  | local | $0.0083 | 3 | stop | FAIL | 1 | 14,837 | 7,251 | 0 | 39,936 | 0 |
| 1-review-1 | csharp1b | review | 1 |  | local | $0.0101 | 4 | stop | PASS | 0 | 20,949 | 7,784 | 0 | 55,808 | 0 |
| 1-review-2 | csharp1 | review | 2 |  | local | $0.0108 | 4 | stop | PASS | 0 | 20,695 | 8,875 | 0 | 58,624 | 0 |
| 1-review-2 | csharp1b | review | 2 |  | local | $0.0104 | 3 | stop | PASS | 0 | 20,325 | 8,536 | 0 | 38,144 | 0 |
| 1-review-3 | csharp1 | review | 3 |  | local | $0.0134 | 4 | stop | FAIL | 1 | 22,621 | 11,991 | 0 | 65,792 | 0 |
| 1-review-4 | csharp1 | review | 4 |  | local | $0.0087 | 3 | stop | FAIL | 1 | 11,676 | 8,844 | 0 | 46,336 | 0 |
| 1-tests-1a | csharp1 | tests | 1a |  | local | $0.0100 | 4 | stop | PASS | 0 | 17,950 | 8,497 | 0 | 60,160 | 0 |
| 1-tests-1a | csharp1b | tests | 1a |  | local | $0.0146 | 2 | stop | FAIL | 1 | 16,326 | 16,369 | 0 | 29,696 | 0 |
| 1-tests-1b | csharp1 | tests | 1b |  | local | $0.0106 | 3 | stop | FAIL | 1 | 16,147 | 10,164 | 0 | 43,520 | 0 |
| 1-tests-1b | csharp1b | tests | 1b |  | local | $0.0114 | 1 | stop | FAIL | 1 | 14,666 | 12,429 | 0 | 0 | 0 |
| 1-tests-2 | csharp1 | tests | 2 |  | local | $0.0149 | 4 | stop | FAIL | 1 | 19,656 | 15,152 | 0 | 83,712 | 0 |
| 1-tests-2 | csharp1b | tests | 2 |  | local | $0.0109 | 2 | stop | PASS | 0 | 17,328 | 10,460 | 0 | 23,040 | 0 |
| 1-tests-3 | csharp1 | tests | 3 |  | local | $0.0078 | 1 | stop | PASS | 0 | 14,279 | 7,096 | 0 | 0 | 0 |
| 1-tests-4 | csharp1 | tests | 4 |  | local | $0.0092 | 2 | stop | FAIL | 1 | 17,003 | 7,992 | 0 | 21,760 | 0 |
| 1-idiom-1 | csharp1 | idiom | 1 |  | local | $0.0089 | 4 | stop | PASS | 0 | 18,693 | 6,519 | 0 | 67,328 | 0 |
| 1-idiom-1 | csharp1b | idiom | 1 |  | local | $0.0094 | 3 | stop | PASS | 0 | 13,523 | 9,245 | 0 | 45,568 | 0 |
| 1-idiom-2 | csharp1 | idiom | 2 |  | local | $0.0084 | 3 | stop | FAIL | 1 | 8,435 | 9,420 | 0 | 52,992 | 0 |
| 1-idiom-2 | csharp1b | idiom | 2 |  | local | $0.0088 | 3 | stop | PASS | 0 | 16,446 | 7,387 | 0 | 42,496 | 0 |
| 1-idiom-3 | csharp1 | idiom | 3 |  | local | $0.0055 | 1 | stop | PASS | 0 | 14,266 | 3,633 | 0 | 0 | 0 |
| 1-idiom-4 | csharp1 | idiom | 4 |  | local | $0.0070 | 3 | stop | FAIL | 1 | 9,164 | 7,005 | 0 | 50,944 | 0 |
| 2-implement | csharp2 | implement |  |  | local | $0.0413 | 31 | stop |  | 0 | 29,567 | 37,201 | 0 | 1,465,088 | 0 |
| 2-fix-1 | csharp2 | fix | 1 |  | local | $0.0040 | 5 | stop |  | 0 | 14,536 | 722 | 0 | 50,432 | 0 |
| 2-review-1 | csharp2 | review | 1 |  | local | $0.0262 | 5 | stop | PASS | 0 | 56,023 | 2,641 | 17,578 | 79,616 | 0 |
| 2-review-2 | csharp2 | review | 2 |  | local | $0.0210 | 5 | stop | PASS | 0 | 22,212 | 1,357 | 21,818 | 116,992 | 0 |
| 2-tests-1a | csharp2 | tests | 1a |  | local | $0.0243 | 2 | stop | FAIL | 1 | 17,071 | 633 | 30,080 | 43,392 | 0 |
| 2-tests-1b | csharp2 | tests | 1b |  | local | $0.0133 | 1 | stop | PASS | 0 | 14,536 | 13 | 15,355 | 0 | 0 |
| 2-tests-2 | csharp2 | tests | 2 |  | local | $0.0183 | 5 | stop | PASS | 0 | 28,788 | 542 | 16,442 | 104,960 | 0 |
| 2-idiom-1 | csharp2 | idiom | 1 |  | local | $0.0117 | 5 | stop | PASS | 0 | 15,957 | 647 | 10,804 | 90,880 | 0 |
| 2-idiom-2 | csharp2 | idiom | 2 |  | local | $0.0169 | 6 | stop | PASS | 0 | 21,747 | 1,232 | 15,747 | 131,072 | 0 |
| 3-implement | csharp3 | implement |  |  | local | $0.0624 | 30 | stop |  | 0 | 154,262 | 15,421 | 15,735 | 1,125,120 | 0 |
| 3-review-1 | csharp3 | review | 1 |  | local | $0.0134 | 4 | stop | PASS | 0 | 29,389 | 9,609 | 637 | 29,952 | 0 |
| 3-tests-1a | csharp3 | tests | 1a |  | local | $0.0127 | 3 | stop | PASS | 0 | 24,787 | 7,926 | 2,900 | 17,408 | 0 |
| 3-tests-1b | csharp3 | tests | 1b |  | local | $0.0133 | 5 | stop | PASS | 0 | 33,330 | 8,438 | 154 | 48,256 | 0 |
| 3-idiom-1 | csharp3 | idiom | 1 |  | local | $0.0114 | 4 | stop | PASS | 0 | 32,739 | 5,967 | 59 | 28,672 | 0 |
| 4-implement | csharp3 | implement |  |  | local | $0.0335 | 33 | stop |  | 0 | 71,070 | 14,804 | 0 | 1,163,008 | 0 |
| 4-fix-1 | csharp3 | fix | 1 |  | local | $0.0133 | 16 | stop |  | 0 | 17,539 | 2,485 | 8,634 | 303,232 | 0 |
| 4-review-1 | csharp3 | review | 1 |  | local | $0.0125 | 5 | stop | PASS | 0 | 33,627 | 4,346 | 2,946 | 46,208 | 0 |
| 4-review-2 | csharp3 | review | 2 |  | local | $0.0106 | 5 | stop | PASS | 0 | 25,761 | 3,115 | 3,892 | 43,648 | 0 |
| 4-tests-1a | csharp3 | tests | 1a |  | local | $0.0159 | 6 | stop | FAIL | 1 | 31,972 | 2,540 | 9,879 | 100,736 | 0 |
| 4-tests-1b | csharp3 | tests | 1b |  | local | $0.0092 | 2 | stop | FAIL | 1 | 10,807 | 523 | 9,619 | 18,304 | 0 |
| 4-tests-2 | csharp3 | tests | 2 |  | local | $0.0066 | 1 | stop | PASS | 0 | 9,869 | 18 | 6,767 | 0 | 0 |
| 4-idiom-1 | csharp3 | idiom | 1 |  | local | $0.0091 | 4 | stop | PASS | 0 | 27,136 | 1,049 | 3,468 | 28,288 | 0 |
| 4-idiom-2 | csharp3 | idiom | 2 |  | local | $0.0092 | 6 | stop | PASS | 0 | 25,065 | 1,618 | 3,302 | 63,872 | 0 |
| 5-implement | csharp5 | implement |  |  | local | $0.0365 | 28 | stop |  | 0 | 46,560 | 24,824 | 0 | 1,404,160 | 0 |
| 5-fix-1 | csharp5 | fix | 1 |  | local | $0.0208 | 15 | stop |  | 0 | 36,264 | 15,188 | 286 | 366,208 | 0 |
| 5-fix-2 | csharp5 | fix | 2 |  | local | $0.0073 | 15 | stop |  | 0 | 15,409 | 3,539 | 0 | 220,672 | 0 |
| 5-review-1 | csharp5 | review | 1 |  | local | $0.0125 | 6 | stop | PASS | 0 | 16,255 | 12,552 | 0 | 90,880 | 0 |
| 5-review-2 | csharp5 | review | 2 |  | local | $0.0120 | 6 | stop | PASS | 0 | 11,310 | 13,477 | 0 | 87,296 | 0 |
| 5-review-3 | csharp5 | review | 3 |  | local | $0.0125 | 5 | stop | PASS | 0 | 17,243 | 12,558 | 0 | 60,928 | 0 |
| 5-tests-1a | csharp5 | tests | 1a |  | local | $0.0137 | 3 | stop | PASS | 0 | 15,537 | 15,127 | 0 | 49,152 | 0 |
| 5-tests-1b | csharp5 | tests | 1b |  | local | $0.0251 | 4 | stop | FAIL | 2 | 15,821 | 31,597 | 0 | 105,216 | 0 |
| 5-tests-2 | csharp5 | tests | 2 |  | local | $0.0197 | 3 | stop | FAIL | 1 | 15,353 | 23,967 | 0 | 65,280 | 0 |
| 5-tests-3 | csharp5 | tests | 3 |  | local | $0.0142 | 3 | stop | PASS | 0 | 14,142 | 16,441 | 0 | 40,192 | 0 |
| 5-idiom-1 | csharp5 | idiom | 1 |  | local | $0.0063 | 3 | stop | FAIL | 1 | 9,144 | 6,157 | 0 | 31,488 | 0 |
| 5-idiom-2 | csharp5 | idiom | 2 |  | local | $0.0108 | 4 | stop | PASS | 0 | 15,320 | 10,774 | 0 | 50,432 | 0 |
| 5-idiom-3 | csharp5 | idiom | 3 |  | local | $0.0086 | 3 | stop | PASS | 0 | 14,083 | 7,944 | 0 | 32,256 | 0 |
| 6-implement | csharp5 | implement |  |  | local | $0.0205 | 23 | stop |  | 0 | 30,033 | 13,489 | 0 | 705,792 | 0 |
| 6-fix-1 | csharp5 | fix | 1 |  | local | $0.0108 | 19 | stop |  | 0 | 22,121 | 5,642 | 0 | 320,512 | 0 |
| 6-review-1 | csharp5 | review | 1 |  | local | $0.0062 | 5 | stop | PASS | 0 | 15,139 | 3,805 | 0 | 51,968 | 0 |
| 6-review-2 | csharp5 | review | 2 |  | local | $0.0058 | 3 | stop | PASS | 0 | 13,899 | 3,938 | 0 | 22,272 | 0 |
| 6-tests-1a | csharp5 | tests | 1a |  | local | $0.0000 | 0 | ? | FAIL | 1 | 0 | 0 | 0 | 0 | 0 |
| 6-tests-1b | csharp5 | tests | 1b |  | local | $0.0000 | 0 | ? | FAIL | 1 | 0 | 0 | 0 | 0 | 0 |
| 6-tests-2 | csharp5 | tests | 2 |  | local | $0.0076 | 4 | stop | PASS | 0 | 16,028 | 5,742 | 0 | 43,520 | 0 |
| 6-idiom-1 | csharp5 | idiom | 1 |  | local | $0.0000 | 0 | ? | FAIL | 1 | 0 | 0 | 0 | 0 | 0 |
| 6-idiom-2 | csharp5 | idiom | 2 |  | local | $0.0078 | 6 | stop | PASS | 0 | 15,386 | 5,764 | 0 | 80,384 | 0 |
| 7-implement | csharp5 | implement |  |  | local | $0.0722 | 52 | stop |  | 0 | 56,303 | 52,901 | 0 | 3,550,464 | 0 |
| 7-implement | csharp7 | implement |  |  | local | $0.1257 | 19 | tool-calls |  | 0 | 137,023 | 133,454 | 0 | 1,065,728 | 0 |
| 7-implement | csharp7b | implement |  |  | local | $0.0730 | 55 | stop |  | 0 | 124,146 | 31,106 | 0 | 3,589,120 | 0 |
| 7-fix-1 | csharp5 | fix | 1 |  | local | $0.0306 | 15 | stop |  | 0 | 52,330 | 19,099 | 4,194 | 531,840 | 0 |
| 7-fix-1 | csharp7b | fix | 1 |  | local | $0.0078 | 12 | stop |  | 0 | 17,279 | 1,861 | 2,247 | 184,960 | 0 |
| 7-fix-2 | csharp5 | fix | 2 |  | local | $0.0220 | 23 | stop |  | 0 | 31,172 | 15,605 | 0 | 690,176 | 0 |
| 7-fix-2 | csharp7b | fix | 2 |  | local | $0.0141 | 11 | stop |  | 0 | 41,689 | 2,365 | 3,350 | 170,240 | 0 |
| 7-fix-3 | csharp5 | fix | 3 |  | local | $0.0132 | 14 | stop |  | 0 | 25,303 | 8,264 | 0 | 308,480 | 0 |
| 7-review-1 | csharp5 | review | 1 |  | local | $0.0218 | 4 | stop | FAIL | 1 | 23,397 | 24,024 | 0 | 110,080 | 0 |
| 7-review-1 | csharp7b | review | 1 |  | local | $0.0217 | 5 | stop | FAIL | 1 | 30,430 | 911 | 20,276 | 150,656 | 0 |
| 7-review-2 | csharp5 | review | 2 |  | local | $0.0245 | 6 | stop | PASS | 0 | 27,888 | 25,532 | 0 | 210,432 | 0 |
| 7-review-2 | csharp7b | review | 2 |  | local | $0.0242 | 4 | stop | FAIL | 2 | 31,149 | 1,233 | 23,857 | 119,552 | 0 |
| 7-review-3 | csharp5 | review | 3 |  | local | $0.0192 | 4 | stop | FAIL | 1 | 29,609 | 18,289 | 0 | 83,712 | 0 |
| 7-review-3 | csharp7b | review | 3 |  | local | $0.0280 | 5 | stop | PASS | 0 | 30,352 | 522 | 29,844 | 180,992 | 0 |
| 7-review-4 | csharp5 | review | 4 |  | local | $0.0197 | 4 | stop | FAIL | 1 | 28,572 | 19,302 | 0 | 100,864 | 0 |
| 7-tests-1a | csharp5 | tests | 1a |  | local | $0.0283 | 5 | stop | FAIL | 1 | 41,826 | 27,587 | 0 | 125,696 | 0 |
| 7-tests-1a | csharp7b | tests | 1a |  | local | $0.0189 | 1 | stop | PASS | 0 | 23,999 | 15 | 20,601 | 0 | 0 |
| 7-tests-1b | csharp5 | tests | 1b |  | local | $0.0158 | 1 | stop | FAIL | 1 | 15,439 | 18,796 | 0 | 6,656 | 0 |
| 7-tests-1b | csharp7b | tests | 1b |  | local | $0.0178 | 1 | stop | PASS | 0 | 24,099 | 13 | 18,883 | 0 | 0 |
| 7-tests-2 | csharp5 | tests | 2 |  | local | $0.0223 | 5 | stop | PASS | 0 | 31,896 | 21,386 | 0 | 166,656 | 0 |
| 7-tests-2 | csharp7b | tests | 2 |  | local | $0.0197 | 4 | stop | PASS | 0 | 27,682 | 1,038 | 18,262 | 126,080 | 0 |
| 7-tests-3 | csharp5 | tests | 3 |  | local | $0.0170 | 1 | stop | FAIL | 1 | 23,099 | 18,097 | 0 | 0 | 0 |
| 7-tests-3 | csharp7b | tests | 3 |  | local | $0.0164 | 1 | stop | PASS | 0 | 24,693 | 13 | 16,658 | 0 | 0 |
| 7-tests-4 | csharp5 | tests | 4 |  | local | $0.0212 | 2 | stop | PASS | 0 | 23,590 | 23,995 | 0 | 23,552 | 0 |
| 7-idiom-1 | csharp5 | idiom | 1 |  | local | $0.0196 | 7 | stop | FAIL | 2 | 30,651 | 17,254 | 0 | 208,640 | 0 |
| 7-idiom-1 | csharp7b | idiom | 1 |  | local | $0.0184 | 7 | stop | PASS | 0 | 28,120 | 912 | 15,188 | 224,768 | 0 |
| 7-idiom-2 | csharp5 | idiom | 2 |  | local | $0.0193 | 4 | stop | FAIL | 1 | 28,782 | 18,546 | 0 | 108,032 | 0 |
| 7-idiom-2 | csharp7b | idiom | 2 |  | local | $0.0234 | 5 | stop | PASS | 0 | 29,917 | 755 | 23,025 | 161,024 | 0 |
| 7-idiom-3 | csharp5 | idiom | 3 |  | local | $0.0269 | 4 | stop | FAIL | 1 | 30,465 | 29,479 | 0 | 103,168 | 0 |
| 7-idiom-3 | csharp7b | idiom | 3 |  | local | $0.0186 | 4 | stop | PASS | 0 | 28,620 | 984 | 16,513 | 106,496 | 0 |
| 7-idiom-4 | csharp5 | idiom | 4 |  | local | $0.0271 | 8 | stop | PASS | 0 | 37,864 | 25,485 | 0 | 275,456 | 0 |
| 8-implement | container-run | implement |  |  | local | $0.0561 | 46 | stop |  | 0 | 89,231 | 26,858 | 40 | 2,668,032 | 0 |
| 8-implement | s3logs | implement |  |  | ec2 | $0.1170 | 67 | stop |  | 0 | 134,912 | 56,953 | 12,518 | 5,926,528 | 0 |
| 8-fix-1 | container-run | fix | 1 |  | local | $0.0065 | 6 | stop |  | 0 | 17,742 | 1,172 | 1,892 | 83,968 | 0 |
| 8-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0202 | 18 | stop |  | 0 | 45,895 | 9,262 | 1,799 | 400,512 | 0 |
| 8-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0139 | 16 | stop |  | 0 | 44,546 | 2,834 | 264 | 298,368 | 0 |
| 8-review-1 | container-run | review | 1 |  | local | $0.0000 | 0 | ? | FAIL | 1 | 0 | 0 | 0 | 0 | 0 |
| 8-review-1 | s3logs | review | 1 |  | ec2 | $0.0170 | 6 | stop | FAIL | 1 | 33,213 | 13,365 | 0 | 121,088 | 0 |
| 8-review-2 | container-run | review | 2 |  | local | $0.0111 | 6 | stop | PASS | 0 | 23,603 | 8,072 | 0 | 88,576 | 0 |
| 8-review-2 | s3logs | review | 2 |  | ec2 | $0.0276 | 5 | stop | PASS | 0 | 61,185 | 13,413 | 7,154 | 81,280 | 0 |
| 8-review-3 | s3logs | review | 3 |  | ec2 | $0.0374 | 7 | stop | PASS | 0 | 61,911 | 23,006 | 10,557 | 230,144 | 0 |
| 8-tests-1a | container-run | tests | 1a |  | local | $0.0197 | 5 | stop | PASS | 0 | 25,565 | 1,377 | 19,106 | 74,368 | 0 |
| 8-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0103 | 2 | stop | PASS | 0 | 26,607 | 6,552 | 0 | 18,176 | 0 |
| 8-tests-1b | container-run | tests | 1b |  | local | $0.0210 | 4 | stop | PASS | 0 | 24,011 | 1,115 | 21,906 | 70,912 | 0 |
| 8-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0104 | 3 | stop | PASS | 0 | 20,832 | 8,390 | 0 | 42,240 | 0 |
| 8-tests-2 | container-run | tests | 2 |  | local | $0.0086 | 2 | stop | PASS | 0 | 22,447 | 5,447 | 0 | 13,568 | 0 |
| 8-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0229 | 6 | stop | FAIL | 1 | 24,461 | 823 | 23,824 | 175,232 | 0 |
| 8-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0359 | 7 | stop | PASS | 0 | 65,720 | 19,287 | 11,059 | 206,848 | 0 |
| 8-idiom-1 | container-run | idiom | 1 |  | local | $0.0237 | 7 | stop | FAIL | 1 | 60,969 | 8,247 | 6,054 | 122,368 | 0 |
| 8-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0070 | 3 | stop | PASS | 0 | 20,306 | 3,387 | 0 | 37,120 | 0 |
| 8-idiom-2 | container-run | idiom | 2 |  | local | $0.0089 | 5 | stop | PASS | 0 | 19,710 | 6,270 | 0 | 65,792 | 0 |
| 8-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0178 | 6 | stop | PASS | 0 | 24,300 | 719 | 16,554 | 150,144 | 0 |
| 8-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0155 | 5 | stop | PASS | 0 | 45,200 | 3,907 | 3,700 | 81,920 | 0 |
| 9-implement | s3logs | implement |  |  | ec2 | $0.0293 | 22 | stop |  | 0 | 62,458 | 13,881 | 2,525 | 679,680 | 0 |
| 9-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0101 | 13 | stop |  | 0 | 30,546 | 2,554 | 353 | 213,248 | 0 |
| 9-review-1 | s3logs | review | 1 |  | ec2 | $0.0146 | 7 | stop | PASS | 0 | 35,544 | 7,976 | 1,363 | 81,152 | 0 |
| 9-review-2 | s3logs | review | 2 |  | ec2 | $0.0133 | 7 | stop | PASS | 0 | 35,720 | 5,133 | 2,258 | 81,792 | 0 |
| 9-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0089 | 4 | stop | FAIL | 1 | 26,557 | 1,357 | 3,072 | 23,680 | 0 |
| 9-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0085 | 4 | stop | PASS | 0 | 27,055 | 346 | 3,245 | 27,392 | 0 |
| 9-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0078 | 6 | stop | PASS | 0 | 17,198 | 893 | 4,424 | 78,464 | 0 |
| 9-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0117 | 4 | stop | PASS | 0 | 35,682 | 3,239 | 2,357 | 23,040 | 0 |
| 9-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0054 | 4 | stop | PASS | 0 | 15,633 | 351 | 2,140 | 38,912 | 0 |
| 10-implement | s3logs | implement |  |  | ec2 | $0.0526 | 36 | stop |  | 0 | 83,222 | 24,624 | 8,480 | 1,776,512 | 0 |
| 10-review-1 | s3logs | review | 1 |  | ec2 | $0.0116 | 7 | stop | PASS | 0 | 39,391 | 3,461 | 57 | 88,448 | 0 |
| 10-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0138 | 4 | stop | PASS | 0 | 39,027 | 3,600 | 3,905 | 40,192 | 0 |
| 10-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0124 | 4 | stop | PASS | 0 | 42,365 | 4,210 | 145 | 32,896 | 0 |
| 10-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0107 | 5 | stop | PASS | 0 | 34,531 | 2,434 | 1,589 | 61,184 | 0 |
| 11-implement | s3logs | implement |  |  | ec2 | $0.0580 | 37 | stop |  | 0 | 83,593 | 36,074 | 156 | 2,235,392 | 0 |
| 11-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0179 | 17 | stop |  | 0 | 51,640 | 4,073 | 2,087 | 351,616 | 0 |
| 11-review-1 | s3logs | review | 1 |  | ec2 | $0.0230 | 15 | stop | PASS | 0 | 33,267 | 19,543 | 0 | 396,544 | 0 |
| 11-review-2 | s3logs | review | 2 |  | ec2 | $0.0354 | 11 | stop | PASS | 0 | 76,057 | 17,449 | 8,116 | 252,544 | 0 |
| 11-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0141 | 6 | stop | FAIL | 2 | 20,327 | 13,249 | 0 | 123,648 | 0 |
| 11-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0211 | 5 | stop | FAIL | 2 | 25,690 | 22,218 | 0 | 116,224 | 0 |
| 11-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0284 | 5 | stop | PASS | 0 | 54,431 | 14,516 | 9,485 | 77,696 | 0 |
| 11-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0202 | 8 | stop | FAIL | 1 | 32,483 | 17,920 | 0 | 171,264 | 0 |
| 11-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0197 | 6 | stop | PASS | 0 | 49,344 | 9,909 | 2,513 | 98,048 | 0 |
| 12-implement | s3logs | implement |  |  | ec2 | $0.1188 | 61 | stop |  | 0 | 242,587 | 46,324 | 0 | 4,975,104 | 0 |
| 12-review-1 | s3logs | review | 1 |  | ec2 | $0.0323 | 7 | stop | PASS | 0 | 58,239 | 15,252 | 12,895 | 130,048 | 0 |
| 12-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0215 | 4 | stop | PASS | 0 | 42,888 | 11,045 | 6,597 | 61,184 | 0 |
| 12-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0197 | 4 | stop | PASS | 0 | 40,906 | 4,449 | 11,056 | 68,608 | 0 |
| 12-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0159 | 4 | stop | PASS | 0 | 40,012 | 5,775 | 4,531 | 38,400 | 0 |
| 13-implement | s3logs | implement |  |  | ec2 | $0.1506 | 68 | stop |  | 0 | 179,785 | 89,296 | 0 | 7,437,824 | 0 |
| 13-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0079 | 7 | stop |  | 0 | 22,881 | 3,055 | 0 | 116,992 | 0 |
| 13-review-1 | s3logs | review | 1 |  | ec2 | $0.0327 | 4 | stop | PASS | 0 | 35,406 | 36,324 | 0 | 136,960 | 0 |
| 13-review-2 | s3logs | review | 2 |  | ec2 | $0.0315 | 5 | stop | PASS | 0 | 35,392 | 33,869 | 0 | 190,976 | 0 |
| 13-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0398 | 5 | stop | FAIL | 2 | 48,232 | 41,905 | 0 | 220,416 | 0 |
| 13-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0237 | 5 | stop | PASS | 0 | 34,721 | 22,269 | 0 | 195,584 | 0 |
| 13-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0251 | 6 | stop | PASS | 0 | 49,919 | 19,239 | 0 | 201,472 | 0 |
| 13-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0271 | 7 | stop | PASS | 0 | 46,866 | 22,448 | 0 | 282,368 | 0 |
| 13-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0289 | 8 | stop | PASS | 0 | 49,493 | 23,760 | 0 | 336,384 | 0 |
| 14-implement | s3logs | implement |  |  | ec2 | $0.0301 | 27 | stop |  | 0 | 44,948 | 18,477 | 0 | 1,149,184 | 0 |
| 14-review-1 | s3logs | review | 1 |  | ec2 | $0.0137 | 6 | stop | PASS | 0 | 26,111 | 10,988 | 0 | 98,304 | 0 |
| 14-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0146 | 6 | stop | PASS | 0 | 17,658 | 15,297 | 0 | 88,320 | 0 |
| 14-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0174 | 5 | stop | PASS | 0 | 23,034 | 17,738 | 0 | 91,136 | 0 |
| 14-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0145 | 8 | stop | PASS | 0 | 26,268 | 11,527 | 0 | 156,416 | 0 |
| 15-implement | s3logs | implement |  |  | ec2 | $0.0262 | 24 | stop |  | 0 | 38,975 | 17,946 | 0 | 825,088 | 0 |
| 15-review-1 | s3logs | review | 1 |  | ec2 | $0.0152 | 8 | stop | PASS | 0 | 24,540 | 13,163 | 0 | 157,184 | 0 |
| 15-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0088 | 4 | stop | PASS | 0 | 18,461 | 6,809 | 0 | 41,216 | 0 |
| 15-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0182 | 11 | stop | PASS | 0 | 25,501 | 16,131 | 0 | 275,456 | 0 |
| 15-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0059 | 3 | stop | PASS | 0 | 13,890 | 3,964 | 0 | 27,136 | 0 |
| 16-implement | s3logs | implement |  |  | ec2 | $0.1091 | 66 | stop |  | 0 | 97,593 | 60,945 | 0 | 6,770,688 | 0 |
| 16-review-1 | s3logs | review | 1 |  | ec2 | $0.0208 | 7 | stop | PASS | 0 | 34,813 | 18,040 | 0 | 181,504 | 0 |
| 16-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0203 | 5 | stop | PASS | 0 | 30,756 | 19,093 | 0 | 133,376 | 0 |
| 16-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0263 | 6 | stop | PASS | 0 | 37,730 | 25,453 | 0 | 168,192 | 0 |
| 16-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0199 | 7 | stop | PASS | 0 | 32,985 | 17,084 | 0 | 200,960 | 0 |
| 17-implement | s3logs | implement |  |  | ec2 | $0.0783 | 53 | stop |  | 0 | 73,519 | 48,577 | 0 | 4,297,472 | 0 |
| 17-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0099 | 14 | stop |  | 0 | 22,888 | 4,473 | 0 | 269,824 | 0 |
| 17-review-1 | s3logs | review | 1 |  | ec2 | $0.0130 | 6 | stop | PASS | 0 | 23,602 | 10,556 | 0 | 123,392 | 0 |
| 17-review-2 | s3logs | review | 2 |  | ec2 | $0.0239 | 10 | stop | PASS | 0 | 67,893 | 11,117 | 0 | 228,608 | 0 |
| 17-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0181 | 7 | stop | FAIL | 1 | 26,077 | 16,794 | 0 | 176,896 | 0 |
| 17-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0205 | 12 | stop | PASS | 0 | 32,744 | 16,316 | 0 | 367,104 | 0 |
| 17-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0267 | 7 | stop | PASS | 0 | 74,111 | 14,436 | 123 | 117,760 | 0 |
| 17-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0172 | 7 | stop | PASS | 0 | 27,277 | 15,019 | 0 | 181,248 | 0 |
| 17-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0217 | 9 | stop | PASS | 0 | 35,387 | 18,115 | 0 | 279,552 | 0 |
| 18-implement | s3logs | implement |  |  | ec2 | $0.1367 | 73 | stop |  | 0 | 128,986 | 71,864 | 0 | 8,705,024 | 0 |
| 18-review-1 | s3logs | review | 1 |  | ec2 | $0.0246 | 10 | stop | PASS | 0 | 40,372 | 20,227 | 0 | 342,016 | 0 |
| 18-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0256 | 8 | stop | PASS | 0 | 34,417 | 24,588 | 0 | 254,720 | 0 |
| 18-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0279 | 8 | stop | PASS | 0 | 46,586 | 24,374 | 0 | 217,088 | 0 |
| 18-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0324 | 9 | stop | PASS | 0 | 38,981 | 32,615 | 0 | 332,032 | 0 |
| 19-implement | s3logs | implement |  |  | ec2 | $0.0680 | 46 | stop |  | 0 | 71,512 | 43,968 | 0 | 3,315,712 | 0 |
| 19-review-1 | s3logs | review | 1 |  | ec2 | $0.0206 | 10 | stop | PASS | 0 | 47,607 | 11,951 | 0 | 315,392 | 0 |
| 19-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0242 | 7 | stop | PASS | 0 | 49,914 | 17,672 | 0 | 229,120 | 0 |
| 19-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0280 | 9 | stop | PASS | 0 | 50,157 | 22,455 | 0 | 302,592 | 0 |
| 19-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0197 | 9 | stop | PASS | 0 | 40,819 | 12,965 | 0 | 303,616 | 0 |
| 20-implement | s3logs | implement |  |  | ec2 | $0.1448 | 82 | stop |  | 0 | 108,970 | 77,825 | 0 | 9,923,072 | 0 |
| 20-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0145 | 13 | stop |  | 0 | 35,749 | 6,097 | 0 | 371,968 | 0 |
| 20-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0165 | 12 | stop |  | 0 | 37,497 | 8,354 | 0 | 397,312 | 0 |
| 20-review-1 | s3logs | review | 1 |  | ec2 | $0.0290 | 9 | stop | PASS | 0 | 48,538 | 24,274 | 0 | 324,352 | 0 |
| 20-review-2 | s3logs | review | 2 |  | ec2 | $0.0278 | 8 | stop | PASS | 0 | 49,555 | 22,363 | 0 | 306,432 | 0 |
| 20-review-3 | s3logs | review | 3 |  | ec2 | $0.0285 | 8 | stop | PASS | 0 | 51,637 | 22,699 | 0 | 310,016 | 0 |
| 20-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0262 | 7 | stop | FAIL | 1 | 44,090 | 22,423 | 0 | 248,320 | 0 |
| 20-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0273 | 5 | stop | FAIL | 2 | 38,221 | 26,619 | 0 | 184,576 | 0 |
| 20-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0349 | 7 | stop | FAIL | 1 | 43,350 | 35,371 | 0 | 288,256 | 0 |
| 20-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0324 | 7 | stop | PASS | 0 | 47,832 | 29,986 | 0 | 302,592 | 0 |
| 20-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0262 | 9 | stop | FAIL | 1 | 47,072 | 20,360 | 0 | 346,880 | 0 |
| 20-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0284 | 13 | stop | PASS | 0 | 48,532 | 20,523 | 0 | 597,248 | 0 |
| 20-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0272 | 9 | stop | PASS | 0 | 50,815 | 20,194 | 0 | 380,416 | 0 |
| 21-implement | s3logs | implement |  |  | ec2 | $0.1481 | 52 | stop |  | 0 | 370,156 | 47,609 | 22 | 5,032,960 | 0 |
| 21-review-1 | s3logs | review | 1 |  | ec2 | $0.0270 | 9 | stop | PASS | 0 | 52,912 | 19,646 | 0 | 336,128 | 0 |
| 21-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0245 | 9 | stop | PASS | 0 | 39,686 | 19,909 | 0 | 379,136 | 0 |
| 21-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0259 | 10 | stop | PASS | 0 | 48,349 | 18,884 | 0 | 393,984 | 0 |
| 21-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0169 | 6 | stop | PASS | 0 | 38,729 | 10,913 | 0 | 173,824 | 0 |
| 22-implement | s3logs | implement |  |  | ec2 | $0.1345 | 72 | stop |  | 0 | 126,719 | 69,185 | 0 | 8,708,352 | 0 |
| 22-review-1 | s3logs | review | 1 |  | ec2 | $0.0341 | 10 | stop | PASS | 0 | 64,236 | 25,395 | 0 | 464,896 | 0 |
| 22-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0234 | 5 | stop | PASS | 0 | 42,598 | 19,419 | 0 | 174,080 | 0 |
| 22-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0245 | 5 | stop | PASS | 0 | 31,825 | 24,713 | 0 | 168,960 | 0 |
| 22-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0255 | 9 | stop | PASS | 0 | 47,666 | 18,454 | 0 | 403,968 | 0 |
| 23-implement | s3logs | implement |  |  | ec2 | $0.0721 | 65 | stop |  | 0 | 84,773 | 27,092 | 0 | 5,080,576 | 0 |
| 23-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0067 | 9 | stop |  | 0 | 18,843 | 2,452 | 0 | 132,864 | 0 |
| 23-review-1 | s3logs | review | 1 |  | ec2 | $0.0208 | 10 | stop | PASS | 0 | 32,118 | 18,067 | 0 | 260,608 | 0 |
| 23-review-2 | s3logs | review | 2 |  | ec2 | $0.0155 | 10 | stop | PASS | 0 | 29,744 | 10,970 | 0 | 246,016 | 0 |
| 23-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0153 | 6 | stop | PASS | 0 | 26,196 | 13,366 | 0 | 104,192 | 0 |
| 23-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0112 | 4 | stop | PASS | 0 | 15,044 | 11,353 | 0 | 62,464 | 0 |
| 23-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0122 | 5 | stop | PASS | 0 | 21,156 | 10,477 | 0 | 85,760 | 0 |
| 23-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0135 | 6 | stop | FAIL | 1 | 26,621 | 10,346 | 0 | 115,968 | 0 |
| 23-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0120 | 6 | stop | PASS | 0 | 23,778 | 8,980 | 0 | 119,296 | 0 |
| 24-implement | s3logs | implement |  |  | ec2 | $0.0839 | 64 | stop |  | 0 | 90,559 | 39,112 | 0 | 5,447,424 | 0 |
| 24-review-1 | s3logs | review | 1 |  | ec2 | $0.0221 | 10 | stop | PASS | 0 | 49,988 | 13,398 | 0 | 324,864 | 0 |
| 24-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0251 | 8 | stop | PASS | 0 | 49,188 | 18,752 | 0 | 269,312 | 0 |
| 24-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0296 | 9 | stop | PASS | 0 | 43,894 | 26,864 | 0 | 321,536 | 0 |
| 24-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0254 | 12 | stop | PASS | 0 | 42,851 | 19,613 | 0 | 432,896 | 0 |
| 25-implement | s3logs | implement |  |  | ec2 | $0.0751 | 35 | stop |  | 0 | 109,306 | 39,724 | 0 | 3,543,552 | 0 |
| 25-review-1 | s3logs | review | 1 |  | ec2 | $0.0196 | 18 | stop | PASS | 0 | 42,105 | 10,316 | 0 | 499,200 | 0 |
| 25-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0188 | 9 | stop | PASS | 0 | 35,955 | 13,866 | 0 | 241,920 | 0 |
| 25-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0183 | 10 | stop | PASS | 0 | 35,695 | 13,166 | 0 | 256,768 | 0 |
| 25-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0102 | 6 | stop | PASS | 0 | 18,355 | 8,389 | 0 | 85,504 | 0 |
| 26-implement | s3logs | implement |  |  | ec2 | $0.2707 | 114 | stop |  | 0 | 338,226 | 92,240 | 0 | 19,350,784 | 0 |
| 26-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0041 | 4 | stop |  | 0 | 15,112 | 714 | 0 | 43,520 | 0 |
| 26-review-1 | s3logs | review | 1 |  | ec2 | $0.0291 | 9 | stop | PASS | 0 | 42,274 | 26,413 | 0 | 336,128 | 0 |
| 26-review-2 | s3logs | review | 2 |  | ec2 | $0.0309 | 8 | stop | PASS | 0 | 36,704 | 31,850 | 0 | 260,096 | 0 |
| 26-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0324 | 12 | stop | FAIL | 1 | 56,581 | 24,810 | 0 | 513,024 | 0 |
| 26-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0247 | 5 | stop | FAIL | 1 | 29,420 | 26,001 | 0 | 154,112 | 0 |
| 26-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0214 | 5 | stop | PASS | 0 | 29,714 | 21,030 | 0 | 136,448 | 0 |
| 26-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0309 | 9 | stop | PASS | 0 | 42,319 | 29,156 | 0 | 328,704 | 0 |
| 26-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0272 | 9 | stop | PASS | 0 | 34,997 | 26,207 | 0 | 313,088 | 0 |
| 27-implement | s3logs | implement |  |  | ec2 | $0.5494 | 80 | stop |  | 0 | 127,664 | 36,673 | 56,873 | 12,725,760 | 0 |
| 27-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0298 | 10 | stop |  | 0 | 25,333 | 2,252 | 2,049 | 205,824 | 0 |
| 27-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0139 | 15 | stop |  | 0 | 40,170 | 4,462 | 52 | 299,392 | 0 |
| 27-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0251 | 21 | stop |  | 0 | 61,216 | 9,471 | 1,919 | 581,888 | 0 |
| 27-review-1 | s3logs | review | 1 |  | ec2 | $0.0811 | 9 | stop | FAIL | 1 | 59,816 | 1,496 | 14,870 | 416,896 | 0 |
| 27-review-2 | s3logs | review | 2 |  | ec2 | $0.0902 | 7 | stop | PASS | 0 | 63,745 | 1,908 | 18,761 | 326,784 | 0 |
| 27-review-3 | s3logs | review | 3 |  | ec2 | $0.0352 | 11 | stop | FAIL | 1 | 66,329 | 2,055 | 22,555 | 630,656 | 0 |
| 27-review-4 | s3logs | review | 4 |  | ec2 | $0.0348 | 8 | stop | FAIL | 1 | 70,206 | 1,529 | 23,391 | 421,632 | 0 |
| 27-tests-1a | s3logs | tests | 1a |  | ec2 | $0.1030 | 6 | stop | PASS | 0 | 51,755 | 1,519 | 29,989 | 295,168 | 0 |
| 27-tests-1b | s3logs | tests | 1b |  | ec2 | $0.1036 | 6 | stop | FAIL | 1 | 44,857 | 1,230 | 32,448 | 333,568 | 0 |
| 27-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0934 | 8 | stop | PASS | 0 | 65,567 | 2,038 | 18,439 | 433,920 | 0 |
| 27-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0363 | 10 | stop | PASS | 0 | 70,507 | 1,999 | 23,654 | 551,424 | 0 |
| 27-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0399 | 8 | stop | FAIL | 1 | 58,671 | 1,814 | 33,861 | 493,696 | 0 |
| 27-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0755 | 8 | stop | FAIL | 1 | 52,734 | 1,356 | 14,948 | 380,416 | 0 |
| 27-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.1007 | 7 | stop | PASS | 0 | 71,962 | 2,231 | 20,748 | 352,000 | 0 |
| 27-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0392 | 10 | stop | PASS | 0 | 63,076 | 1,840 | 29,654 | 649,600 | 0 |
| 27-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0494 | 9 | stop | PASS | 0 | 151,800 | 5,863 | 14,006 | 408,320 | 0 |
| 28-implement | s3logs | implement |  |  | ec2 | $0.2089 | 97 | stop |  | 0 | 145,856 | 98,739 | 0 | 15,944,448 | 0 |
| 28-retry-implement | s3logs | implement |  | yes | ec2 | $0.1890 | 110 | stop |  | 0 | 117,408 | 94,922 | 0 | 14,366,208 | 0 |
| 28-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0266 | 30 | stop |  | 0 | 47,763 | 11,071 | 0 | 1,257,728 | 0 |
| 28-retry-fix-1 | s3logs | fix | 1 | yes | ec2 | $0.0172 | 14 | stop |  | 0 | 40,756 | 7,218 | 0 | 490,752 | 0 |
| 28-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0082 | 9 | stop |  | 0 | 21,623 | 3,595 | 0 | 152,064 | 0 |
| 28-retry-fix-2 | s3logs | fix | 2 | yes | ec2 | $0.0173 | 16 | stop |  | 0 | 41,606 | 6,770 | 0 | 523,520 | 0 |
| 28-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0056 | 4 | stop |  | 0 | 21,464 | 726 | 0 | 55,296 | 0 |
| 28-retry-fix-3 | s3logs | fix | 3 | yes | ec2 | $0.0104 | 13 | stop |  | 0 | 26,245 | 3,940 | 0 | 294,912 | 0 |
| 28-review-1 | s3logs | review | 1 |  | ec2 | $0.0370 | 9 | stop | PASS | 0 | 60,812 | 31,437 | 0 | 412,160 | 0 |
| 28-retry-review-1 | s3logs | review | 1 | yes | ec2 | $0.0473 | 14 | stop | PASS | 0 | 77,260 | 35,870 | 0 | 943,104 | 0 |
| 28-review-2 | s3logs | review | 2 |  | ec2 | $0.0369 | 8 | stop | PASS | 0 | 59,552 | 31,983 | 0 | 388,864 | 0 |
| 28-retry-review-2 | s3logs | review | 2 | yes | ec2 | $0.0438 | 15 | stop | FAIL | 1 | 77,049 | 30,270 | 0 | 983,040 | 0 |
| 28-review-3 | s3logs | review | 3 |  | ec2 | $0.0408 | 9 | stop | PASS | 0 | 60,297 | 36,713 | 0 | 477,440 | 0 |
| 28-retry-review-3 | s3logs | review | 3 | yes | ec2 | $0.0502 | 17 | stop | PASS | 0 | 92,147 | 31,934 | 0 | 1,265,408 | 0 |
| 28-review-4 | s3logs | review | 4 |  | ec2 | $0.0447 | 13 | stop | PASS | 0 | 74,792 | 34,612 | 0 | 771,840 | 0 |
| 28-retry-review-4 | s3logs | review | 4 | yes | ec2 | $0.0448 | 12 | stop | PASS | 0 | 79,374 | 32,989 | 0 | 792,576 | 0 |
| 28-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0316 | 8 | stop | FAIL | 1 | 48,384 | 27,154 | 0 | 430,592 | 0 |
| 28-retry-tests-1a | s3logs | tests | 1a | yes | ec2 | $0.0394 | 6 | stop | FAIL | 1 | 62,489 | 35,241 | 0 | 348,672 | 0 |
| 28-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0321 | 5 | stop | FAIL | 2 | 47,307 | 30,097 | 0 | 258,048 | 0 |
| 28-retry-tests-1b | s3logs | tests | 1b | yes | ec2 | $0.0435 | 11 | stop | FAIL | 1 | 82,294 | 30,320 | 0 | 774,144 | 0 |
| 28-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0451 | 9 | stop | FAIL | 1 | 52,101 | 45,359 | 0 | 524,800 | 0 |
| 28-retry-tests-2 | s3logs | tests | 2 | yes | ec2 | $0.0400 | 9 | stop | PASS | 0 | 78,240 | 28,597 | 0 | 562,432 | 0 |
| 28-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0380 | 7 | stop | PASS | 0 | 68,837 | 30,608 | 0 | 375,296 | 0 |
| 28-retry-tests-3 | s3logs | tests | 3 | yes | ec2 | $0.0437 | 10 | stop | FAIL | 1 | 68,206 | 37,014 | 0 | 610,304 | 0 |
| 28-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0369 | 7 | stop | FAIL | 1 | 61,633 | 31,745 | 0 | 346,112 | 0 |
| 28-retry-tests-4 | s3logs | tests | 4 | yes | ec2 | $0.0364 | 8 | stop | PASS | 0 | 68,001 | 27,330 | 0 | 488,448 | 0 |
| 28-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0345 | 11 | stop | PASS | 0 | 62,088 | 25,184 | 0 | 600,064 | 0 |
| 28-retry-idiom-1 | s3logs | idiom | 1 | yes | ec2 | $0.0391 | 9 | stop | FAIL | 1 | 71,105 | 30,193 | 0 | 498,688 | 0 |
| 28-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0272 | 6 | stop | FAIL | 1 | 50,725 | 21,452 | 0 | 262,912 | 0 |
| 28-retry-idiom-2 | s3logs | idiom | 2 | yes | ec2 | $0.0441 | 10 | stop | PASS | 0 | 75,712 | 34,808 | 0 | 641,024 | 0 |
| 28-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0402 | 12 | stop | FAIL | 1 | 79,400 | 26,639 | 0 | 730,368 | 0 |
| 28-retry-idiom-3 | s3logs | idiom | 3 | yes | ec2 | $0.0425 | 10 | stop | PASS | 0 | 69,468 | 34,288 | 0 | 648,704 | 0 |
| 28-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0416 | 11 | stop | FAIL | 1 | 65,723 | 34,315 | 0 | 643,840 | 0 |
| 28-retry-idiom-4 | s3logs | idiom | 4 | yes | ec2 | $0.0367 | 11 | stop | PASS | 0 | 68,019 | 26,038 | 0 | 653,568 | 0 |
| 29-implement | s3logs | implement |  |  | ec2 | $0.1695 | 97 | stop |  | 0 | 116,018 | 86,912 | 0 | 12,374,016 | 0 |
| 29-review-1 | s3logs | review | 1 |  | ec2 | $0.0327 | 8 | stop | PASS | 0 | 56,877 | 26,430 | 0 | 384,768 | 0 |
| 29-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0295 | 6 | stop | PASS | 0 | 48,926 | 25,409 | 0 | 279,552 | 0 |
| 29-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0327 | 10 | stop | PASS | 0 | 51,325 | 26,774 | 0 | 528,128 | 0 |
| 29-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0281 | 7 | stop | PASS | 0 | 53,007 | 21,530 | 0 | 324,352 | 0 |
| 30-implement | s3logs | implement |  |  | ec2 | $0.4538 | 127 | stop |  | 0 | 756,254 | 139,328 | 131 | 27,904,512 | 0 |
| 30-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0279 | 20 | stop |  | 0 | 51,360 | 16,252 | 0 | 837,120 | 0 |
| 30-review-1 | s3logs | review | 1 |  | ec2 | $0.0575 | 14 | stop | FAIL | 1 | 82,720 | 47,969 | 0 | 1,095,168 | 0 |
| 30-review-2 | s3logs | review | 2 |  | ec2 | $0.0645 | 16 | stop | PASS | 0 | 129,062 | 41,393 | 0 | 1,251,328 | 0 |
| 30-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0406 | 14 | stop | PASS | 0 | 75,196 | 26,395 | 0 | 954,112 | 0 |
| 30-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0448 | 9 | stop | FAIL | 2 | 74,638 | 36,229 | 0 | 643,584 | 0 |
| 30-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0437 | 12 | stop | PASS | 0 | 81,285 | 29,920 | 0 | 866,816 | 0 |
| 30-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0448 | 12 | stop | FAIL | 2 | 81,326 | 32,104 | 0 | 814,592 | 0 |
| 30-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0617 | 22 | stop | PASS | 0 | 112,256 | 37,471 | 0 | 1,757,184 | 0 |
| 31-implement | s3logs | implement |  |  | ec2 | $0.3678 | 125 | stop |  | 0 | 607,384 | 95,773 | 0 | 24,418,816 | 0 |
| 31-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0313 | 23 | stop |  | 0 | 50,513 | 20,283 | 0 | 966,400 | 0 |
| 31-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0179 | 15 | stop |  | 0 | 39,460 | 8,934 | 0 | 470,784 | 0 |
| 31-review-1 | s3logs | review | 1 |  | ec2 | $0.0461 | 15 | stop | FAIL | 1 | 72,292 | 36,657 | 0 | 859,648 | 0 |
| 31-review-2 | s3logs | review | 2 |  | ec2 | $0.0458 | 14 | stop | PASS | 0 | 78,903 | 33,194 | 0 | 938,752 | 0 |
| 31-review-3 | s3logs | review | 3 |  | ec2 | $0.0409 | 12 | stop | PASS | 0 | 63,917 | 33,203 | 0 | 710,400 | 0 |
| 31-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0361 | 2 | stop | FAIL | 1 | 65,618 | 32,450 | 0 | 36,352 | 0 |
| 31-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0368 | 7 | stop | FAIL | 1 | 52,916 | 33,917 | 0 | 393,984 | 0 |
| 31-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0282 | 4 | stop | FAIL | 2 | 43,871 | 26,141 | 0 | 185,856 | 0 |
| 31-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0404 | 8 | stop | PASS | 0 | 69,418 | 33,189 | 0 | 455,680 | 0 |
| 31-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0415 | 18 | stop | PASS | 0 | 70,705 | 27,331 | 0 | 1,133,824 | 0 |
| 31-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0415 | 12 | stop | FAIL | 1 | 67,877 | 32,270 | 0 | 753,408 | 0 |
| 31-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0393 | 10 | stop | PASS | 0 | 81,344 | 25,944 | 0 | 615,680 | 0 |
| 32-implement | s3logs | implement |  |  | ec2 | $0.4066 | 150 | stop |  | 0 | 227,247 | 147,666 | 0 | 37,026,304 | 0 |
| 32-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0215 | 19 | stop |  | 0 | 49,497 | 7,964 | 0 | 770,560 | 0 |
| 32-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0147 | 17 | stop |  | 0 | 33,967 | 6,306 | 0 | 439,808 | 0 |
| 32-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0349 | 28 | stop |  | 0 | 80,284 | 15,390 | 0 | 1,007,104 | 0 |
| 32-review-1 | s3logs | review | 1 |  | ec2 | $0.0491 | 12 | stop | PASS | 0 | 89,780 | 35,017 | 0 | 896,256 | 0 |
| 32-review-2 | s3logs | review | 2 |  | ec2 | $0.0479 | 11 | stop | PASS | 0 | 88,694 | 34,203 | 0 | 831,232 | 0 |
| 32-review-3 | s3logs | review | 3 |  | ec2 | $0.0461 | 13 | stop | PASS | 0 | 95,010 | 26,929 | 0 | 1,057,280 | 0 |
| 32-review-4 | s3logs | review | 4 |  | ec2 | $0.0507 | 11 | stop | PASS | 0 | 107,310 | 32,020 | 0 | 856,064 | 0 |
| 32-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0496 | 10 | stop | FAIL | 2 | 103,976 | 32,839 | 0 | 726,016 | 0 |
| 32-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0361 | 4 | stop | FAIL | 2 | 85,767 | 23,886 | 0 | 208,384 | 0 |
| 32-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0378 | 7 | stop | PASS | 0 | 71,455 | 28,363 | 0 | 479,744 | 0 |
| 32-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0534 | 7 | stop | FAIL | 2 | 109,327 | 38,891 | 0 | 524,800 | 0 |
| 32-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0393 | 7 | stop | PASS | 0 | 66,217 | 32,053 | 0 | 508,928 | 0 |
| 32-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0794 | 11 | stop | FAIL | 1 | 95,378 | 77,626 | 0 | 1,021,952 | 0 |
| 32-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0491 | 12 | stop | FAIL | 2 | 88,845 | 34,562 | 0 | 966,656 | 0 |
| 32-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0459 | 9 | stop | PASS | 0 | 92,155 | 31,721 | 0 | 670,976 | 0 |
| 32-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0547 | 11 | stop | PASS | 0 | 89,256 | 42,947 | 0 | 964,864 | 0 |
| 33-implement | s3logs | implement |  |  | ec2 | $0.2130 | 114 | stop |  | 0 | 151,409 | 86,204 | 0 | 17,540,864 | 0 |
| 33-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0173 | 17 | stop |  | 0 | 35,786 | 8,442 | 0 | 546,816 | 0 |
| 33-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0230 | 16 | stop |  | 0 | 48,914 | 11,532 | 0 | 659,456 | 0 |
| 33-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0060 | 5 | stop |  | 0 | 19,141 | 2,024 | 0 | 66,816 | 0 |
| 33-review-1 | s3logs | review | 1 |  | ec2 | $0.0463 | 8 | stop | FAIL | 1 | 96,700 | 32,900 | 0 | 472,576 | 0 |
| 33-review-2 | s3logs | review | 2 |  | ec2 | $0.0479 | 11 | stop | PASS | 0 | 85,857 | 35,530 | 0 | 796,928 | 0 |
| 33-review-3 | s3logs | review | 3 |  | ec2 | $0.0495 | 13 | stop | PASS | 0 | 85,199 | 36,861 | 0 | 911,616 | 0 |
| 33-review-4 | s3logs | review | 4 |  | ec2 | $0.0429 | 9 | stop | PASS | 0 | 68,725 | 35,670 | 0 | 610,560 | 0 |
| 33-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0266 | 6 | stop | FAIL | 1 | 50,830 | 20,408 | 0 | 283,648 | 0 |
| 33-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0274 | 5 | stop | FAIL | 2 | 61,200 | 18,873 | 0 | 208,384 | 0 |
| 33-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0430 | 11 | stop | FAIL | 2 | 76,004 | 31,576 | 0 | 771,328 | 0 |
| 33-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0435 | 9 | stop | FAIL | 1 | 78,454 | 33,491 | 0 | 595,712 | 0 |
| 33-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0304 | 6 | stop | PASS | 0 | 57,487 | 23,549 | 0 | 316,928 | 0 |
| 33-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0446 | 14 | stop | PASS | 0 | 88,858 | 27,166 | 0 | 1,018,880 | 0 |
| 33-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0420 | 13 | stop | PASS | 0 | 87,694 | 25,834 | 0 | 808,960 | 0 |
| 33-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0313 | 9 | stop | PASS | 0 | 66,073 | 20,319 | 0 | 477,184 | 0 |
| 33-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0429 | 8 | stop | PASS | 0 | 80,462 | 32,341 | 0 | 556,032 | 0 |
| 34-implement | s3logs | implement |  |  | ec2 | $0.2966 | 146 | stop |  | 0 | 193,042 | 97,151 | 0 | 27,147,520 | 0 |
| 34-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0285 | 19 | stop |  | 0 | 55,800 | 16,368 | 0 | 770,816 | 0 |
| 34-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0066 | 11 | stop |  | 0 | 17,669 | 2,303 | 0 | 174,080 | 0 |
| 34-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0125 | 11 | stop |  | 0 | 32,593 | 5,194 | 0 | 268,544 | 0 |
| 34-review-1 | s3logs | review | 1 |  | ec2 | $0.0567 | 20 | stop | FAIL | 1 | 92,332 | 37,103 | 0 | 1,693,696 | 0 |
| 34-review-2 | s3logs | review | 2 |  | ec2 | $0.0450 | 10 | stop | PASS | 0 | 77,264 | 35,267 | 0 | 674,304 | 0 |
| 34-review-3 | s3logs | review | 3 |  | ec2 | $0.0486 | 15 | stop | PASS | 0 | 98,405 | 28,341 | 0 | 1,184,256 | 0 |
| 34-review-4 | s3logs | review | 4 |  | ec2 | $0.0450 | 10 | stop | PASS | 0 | 87,542 | 31,892 | 0 | 670,208 | 0 |
| 34-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0350 | 5 | stop | FAIL | 1 | 75,550 | 25,039 | 0 | 263,680 | 0 |
| 34-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0428 | 7 | stop | PASS | 0 | 63,801 | 39,110 | 0 | 428,288 | 0 |
| 34-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0316 | 6 | stop | FAIL | 1 | 53,500 | 26,799 | 0 | 312,832 | 0 |
| 34-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0419 | 7 | stop | FAIL | 1 | 69,066 | 35,613 | 0 | 450,816 | 0 |
| 34-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0396 | 9 | stop | PASS | 0 | 70,961 | 30,033 | 0 | 594,944 | 0 |
| 34-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0362 | 7 | stop | FAIL | 1 | 74,929 | 25,248 | 0 | 429,056 | 0 |
| 34-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0367 | 8 | stop | PASS | 0 | 73,421 | 25,786 | 0 | 499,200 | 0 |
| 34-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0345 | 9 | stop | PASS | 0 | 70,843 | 23,017 | 0 | 528,128 | 0 |
| 34-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0399 | 11 | stop | PASS | 0 | 76,550 | 26,970 | 0 | 757,760 | 0 |
| 35-implement | s3logs | implement |  |  | ec2 | $0.1675 | 97 | stop |  | 0 | 251,278 | 57,158 | 0 | 10,638,848 | 0 |
| 35-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0058 | 7 | stop |  | 0 | 18,128 | 1,679 | 0 | 96,000 | 0 |
| 35-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0036 | 4 | stop |  | 0 | 13,404 | 608 | 0 | 38,656 | 0 |
| 35-review-1 | s3logs | review | 1 |  | ec2 | $0.0310 | 12 | stop | PASS | 0 | 64,889 | 19,448 | 0 | 549,888 | 0 |
| 35-review-2 | s3logs | review | 2 |  | ec2 | $0.0362 | 12 | stop | PASS | 0 | 78,360 | 21,641 | 0 | 669,696 | 0 |
| 35-review-3 | s3logs | review | 3 |  | ec2 | $0.0332 | 10 | stop | PASS | 0 | 67,034 | 23,080 | 0 | 460,800 | 0 |
| 35-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0282 | 6 | stop | PASS | 0 | 52,891 | 22,344 | 0 | 259,840 | 0 |
| 35-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0259 | 6 | stop | FAIL | 1 | 50,359 | 20,040 | 0 | 222,208 | 0 |
| 35-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0266 | 7 | stop | FAIL | 1 | 61,041 | 17,040 | 0 | 277,504 | 0 |
| 35-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0384 | 10 | stop | PASS | 0 | 66,039 | 30,029 | 0 | 573,952 | 0 |
| 35-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0303 | 9 | stop | PASS | 0 | 66,110 | 19,727 | 0 | 384,768 | 0 |
| 35-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0354 | 7 | stop | PASS | 0 | 69,961 | 26,903 | 0 | 315,392 | 0 |
| 35-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0159 | 6 | stop | PASS | 0 | 25,599 | 13,345 | 0 | 207,872 | 0 |
| 36-implement | s3logs | implement |  |  | ec2 | $0.0625 | 43 | stop |  | 0 | 92,262 | 27,676 | 0 | 3,425,024 | 0 |
| 36-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0109 | 15 | stop |  | 0 | 27,397 | 4,617 | 0 | 263,680 | 0 |
| 36-review-1 | s3logs | review | 1 |  | ec2 | $0.0152 | 6 | stop | PASS | 0 | 32,679 | 11,105 | 0 | 98,560 | 0 |
| 36-review-2 | s3logs | review | 2 |  | ec2 | $0.0181 | 5 | stop | PASS | 0 | 39,032 | 13,590 | 0 | 72,448 | 0 |
| 36-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0135 | 9 | stop | FAIL | 1 | 23,551 | 10,742 | 0 | 176,640 | 0 |
| 36-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0130 | 6 | stop | PASS | 0 | 18,884 | 12,541 | 0 | 86,272 | 0 |
| 36-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0075 | 4 | stop | PASS | 0 | 11,939 | 6,898 | 0 | 40,448 | 0 |
| 36-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0156 | 7 | stop | PASS | 0 | 39,178 | 8,750 | 0 | 166,400 | 0 |
| 36-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0222 | 5 | stop | PASS | 0 | 52,703 | 14,789 | 0 | 113,664 | 0 |
| 37-implement | s3logs | implement |  |  | ec2 | $0.2069 | 111 | stop |  | 0 | 175,114 | 81,645 | 0 | 16,354,816 | 0 |
| 37-review-1 | s3logs | review | 1 |  | ec2 | $0.0484 | 14 | stop | PASS | 0 | 88,491 | 33,981 | 0 | 933,888 | 0 |
| 37-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0378 | 8 | stop | PASS | 0 | 68,709 | 30,305 | 0 | 389,120 | 0 |
| 37-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0267 | 6 | stop | PASS | 0 | 30,720 | 27,569 | 0 | 247,552 | 0 |
| 37-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0286 | 8 | stop | PASS | 0 | 51,278 | 22,846 | 0 | 326,656 | 0 |
| 38-implement | s3logs | implement |  |  | ec2 | $0.2634 | 126 | stop |  | 0 | 179,254 | 102,038 | 0 | 22,373,888 | 0 |
| 38-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0165 | 12 | stop |  | 0 | 45,973 | 5,513 | 0 | 388,608 | 0 |
| 38-review-1 | s3logs | review | 1 |  | ec2 | $0.0376 | 14 | stop | PASS | 0 | 83,096 | 20,789 | 0 | 794,112 | 0 |
| 38-review-2 | s3logs | review | 2 |  | ec2 | $0.0381 | 12 | stop | PASS | 0 | 85,707 | 22,251 | 0 | 649,472 | 0 |
| 38-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0336 | 7 | stop | PASS | 0 | 44,569 | 33,020 | 0 | 291,840 | 0 |
| 38-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0357 | 8 | stop | FAIL | 1 | 65,121 | 28,037 | 0 | 406,016 | 0 |
| 38-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0373 | 11 | stop | PASS | 0 | 57,696 | 31,448 | 0 | 556,544 | 0 |
| 38-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0290 | 6 | stop | PASS | 0 | 51,032 | 23,966 | 0 | 281,344 | 0 |
| 38-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0249 | 5 | stop | PASS | 0 | 53,286 | 18,140 | 0 | 167,680 | 0 |
| 39-implement | s3logs | implement |  |  | ec2 | $0.3677 | 166 | stop |  | 0 | 525,791 | 112,626 | 0 | 25,390,592 | 0 |
| 39-fix-1 | s3logs | fix | 1 |  | ec2 | $0.1083 | 64 | stop |  | 0 | 151,364 | 35,948 | 0 | 7,317,760 | 0 |
| 39-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0162 | 11 | stop |  | 0 | 42,917 | 7,116 | 0 | 300,544 | 0 |
| 39-review-1 | s3logs | review | 1 |  | ec2 | $0.0419 | 14 | stop | FAIL | 1 | 74,038 | 29,282 | 0 | 897,024 | 0 |
| 39-review-2 | s3logs | review | 2 |  | ec2 | $0.0515 | 20 | stop | PASS | 0 | 87,366 | 32,711 | 0 | 1,526,272 | 0 |
| 39-review-3 | s3logs | review | 3 |  | ec2 | $0.0413 | 13 | stop | PASS | 0 | 89,604 | 22,819 | 0 | 928,768 | 0 |
| 39-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0313 | 7 | stop | FAIL | 1 | 54,068 | 26,015 | 0 | 320,000 | 0 |
| 39-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0328 | 7 | stop | FAIL | 1 | 61,330 | 25,675 | 0 | 337,920 | 0 |
| 39-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0339 | 6 | stop | FAIL | 1 | 49,804 | 31,385 | 0 | 323,584 | 0 |
| 39-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0352 | 10 | stop | PASS | 0 | 51,813 | 29,663 | 0 | 604,160 | 0 |
| 39-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0400 | 11 | stop | PASS | 0 | 56,950 | 35,381 | 0 | 594,432 | 0 |
| 39-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0394 | 10 | stop | PASS | 0 | 71,364 | 28,762 | 0 | 668,928 | 0 |
| 39-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0381 | 8 | stop | PASS | 0 | 60,194 | 32,437 | 0 | 496,384 | 0 |
| 40-implement | s3logs | implement |  |  | ec2 | $0.1125 | 46 | tool-calls |  | 0 | 146,388 | 57,017 | 0 | 6,092,032 | 0 |
| 40-retry-implement | s3logs | implement |  | yes | ec2 | $0.0664 | 55 | stop |  | 0 | 82,322 | 8,099 | 20,472 | 4,205,696 | 0 |
| 40-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0135 | 21 | tool-calls |  | 0 | 28,846 | 6,246 | 0 | 437,248 | 0 |
| 40-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0813 | 58 | stop |  | 0 | 131,682 | 38,463 | 0 | 3,847,680 | 0 |
| 40-fix-3 | s3logs | fix | 3 |  | ec2 | $0.0090 | 14 | stop |  | 0 | 19,812 | 4,494 | 0 | 243,200 | 0 |
| 40-retry-review-1 | s3logs | review | 1 | yes | ec2 | $0.0189 | 7 | stop | PASS | 0 | 62,184 | 6,281 | 740 | 90,112 | 0 |
| 40-review-3 | s3logs | review | 3 |  | ec2 | $0.0464 | 15 | stop | PASS | 0 | 60,637 | 41,564 | 0 | 805,376 | 0 |
| 40-review-4 | s3logs | review | 4 |  | ec2 | $0.0528 | 22 | stop | FAIL | 1 | 67,665 | 45,064 | 0 | 1,170,688 | 0 |
| 40-retry-tests-1a | s3logs | tests | 1a | yes | ec2 | $0.0302 | 15 | stop | PASS | 0 | 64,734 | 13,220 | 6,410 | 434,944 | 0 |
| 40-retry-tests-1b | s3logs | tests | 1b | yes | ec2 | $0.0224 | 10 | stop | PASS | 0 | 33,158 | 1,387 | 18,480 | 279,936 | 0 |
| 40-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0330 | 13 | stop | PASS | 0 | 54,423 | 26,799 | 0 | 476,416 | 0 |
| 40-tests-4 | s3logs | tests | 4 |  | ec2 | $0.0356 | 13 | stop | FAIL | 2 | 47,432 | 32,606 | 0 | 522,752 | 0 |
| 40-retry-idiom-1 | s3logs | idiom | 1 | yes | ec2 | $0.0402 | 12 | stop | PASS | 0 | 113,073 | 12,041 | 5,958 | 495,360 | 0 |
| 40-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0248 | 9 | stop | FAIL | 1 | 46,269 | 19,309 | 0 | 268,800 | 0 |
| 40-idiom-4 | s3logs | idiom | 4 |  | ec2 | $0.0274 | 10 | stop | PASS | 0 | 40,136 | 24,981 | 0 | 301,056 | 0 |
| 41-implement | s3logs | implement |  |  | ec2 | $0.0663 | 44 | stop |  | 0 | 119,407 | 19,452 | 0 | 3,889,920 | 0 |
| 41-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0053 | 7 | stop |  | 0 | 16,854 | 1,528 | 0 | 90,368 | 0 |
| 41-review-1 | s3logs | review | 1 |  | ec2 | $0.0393 | 17 | stop | FAIL | 1 | 92,349 | 19,471 | 0 | 872,448 | 0 |
| 41-review-2 | s3logs | review | 2 |  | ec2 | $0.0458 | 17 | stop | PASS | 0 | 106,982 | 22,447 | 0 | 1,070,848 | 0 |
| 41-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0024 | 1 | stop | PASS | 0 | 10,108 | 316 | 0 | 0 | 0 |
| 41-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0024 | 1 | stop | PASS | 0 | 10,208 | 232 | 0 | 0 | 0 |
| 41-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0036 | 2 | stop | PASS | 0 | 13,091 | 971 | 0 | 12,544 | 0 |
| 41-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0659 | 20 | stop | FAIL | 1 | 90,557 | 55,792 | 0 | 1,305,600 | 0 |
| 41-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0455 | 25 | stop | PASS | 0 | 95,198 | 21,814 | 0 | 1,458,432 | 0 |
| 42-implement | s3logs | implement |  |  | ec2 | $0.1503 | 88 | stop |  | 0 | 237,627 | 36,727 | 0 | 10,536,704 | 0 |
| 42-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0045 | 5 | stop |  | 0 | 16,483 | 530 | 206 | 52,864 | 0 |
| 42-review-1 | s3logs | review | 1 |  | ec2 | $0.0516 | 25 | stop | FAIL | 1 | 103,572 | 21,705 | 8,307 | 1,285,376 | 0 |
| 42-review-2 | s3logs | review | 2 |  | ec2 | $0.0524 | 16 | stop | PASS | 0 | 164,529 | 7,241 | 9,870 | 704,512 | 0 |
| 42-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0054 | 2 | stop | PASS | 0 | 18,980 | 98 | 1,551 | 17,920 | 0 |
| 42-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0051 | 1 | stop | PASS | 0 | 16,891 | 262 | 1,834 | 0 | 0 |
| 42-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0040 | 1 | stop | PASS | 0 | 16,792 | 18 | 430 | 0 | 0 |
| 42-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0128 | 3 | stop | PASS | 0 | 45,285 | 2,059 | 1,970 | 25,344 | 0 |
| 42-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0351 | 16 | stop | PASS | 0 | 78,028 | 2,423 | 15,532 | 873,984 | 0 |
| 43-implement | s3logs | implement |  |  | ec2 | $0.0526 | 44 | stop |  | 0 | 113,207 | 12,649 | 5,071 | 2,280,448 | 0 |
| 43-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0237 | 15 | stop |  | 0 | 84,240 | 2,183 | 648 | 475,008 | 0 |
| 43-fix-2 | s3logs | fix | 2 |  | ec2 | $0.0064 | 6 | stop |  | 0 | 23,430 | 1,240 | 0 | 65,280 | 0 |
| 43-review-1 | s3logs | review | 1 |  | ec2 | $0.0460 | 14 | stop | FAIL | 1 | 120,255 | 10,073 | 14,015 | 526,592 | 0 |
| 43-review-2 | s3logs | review | 2 |  | ec2 | $0.0281 | 12 | stop | FAIL | 1 | 52,683 | 1,742 | 18,268 | 474,624 | 0 |
| 43-review-3 | s3logs | review | 3 |  | ec2 | $0.0394 | 12 | stop | PASS | 0 | 112,921 | 4,964 | 13,016 | 388,864 | 0 |
| 43-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0250 | 6 | stop | PASS | 0 | 39,987 | 1,159 | 21,876 | 144,896 | 0 |
| 43-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0323 | 8 | stop | PASS | 0 | 48,449 | 795 | 28,710 | 306,432 | 0 |
| 43-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0296 | 13 | stop | PASS | 0 | 47,450 | 1,755 | 22,048 | 495,616 | 0 |
| 43-tests-3 | s3logs | tests | 3 |  | ec2 | $0.0260 | 10 | stop | PASS | 0 | 33,934 | 1,787 | 22,618 | 345,600 | 0 |
| 43-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0339 | 13 | stop | PASS | 0 | 49,236 | 2,337 | 26,656 | 557,824 | 0 |
| 43-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0289 | 13 | stop | FAIL | 1 | 46,878 | 1,994 | 20,946 | 499,328 | 0 |
| 43-idiom-3 | s3logs | idiom | 3 |  | ec2 | $0.0210 | 9 | stop | PASS | 0 | 59,171 | 7,983 | 1,452 | 249,856 | 0 |
| 45-implement | s3logs | implement |  |  | ec2 | $0.0469 | 39 | stop |  | 0 | 77,994 | 22,325 | 114 | 2,128,640 | 0 |
| 45-fix-1 | s3logs | fix | 1 |  | ec2 | $0.0624 | 41 | stop |  | 0 | 114,409 | 28,789 | 3,423 | 2,279,168 | 0 |
| 45-review-1 | s3logs | review | 1 |  | ec2 | $0.0315 | 10 | stop | FAIL | 1 | 30,873 | 1,799 | 32,816 | 262,400 | 0 |
| 45-review-2 | s3logs | review | 2 |  | ec2 | $0.0223 | 18 | stop | PASS | 0 | 35,746 | 2,133 | 13,770 | 567,040 | 0 |
| 45-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0143 | 6 | stop | FAIL | 1 | 32,671 | 7,975 | 2,026 | 70,656 | 0 |
| 45-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0147 | 7 | stop | FAIL | 1 | 22,885 | 1,314 | 12,182 | 114,048 | 0 |
| 45-tests-2 | s3logs | tests | 2 |  | ec2 | $0.0108 | 5 | stop | PASS | 0 | 16,173 | 961 | 9,246 | 76,672 | 0 |
| 45-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0183 | 5 | stop | FAIL | 1 | 29,873 | 761 | 15,850 | 104,832 | 0 |
| 45-idiom-2 | s3logs | idiom | 2 |  | ec2 | $0.0047 | 3 | stop | PASS | 0 | 12,959 | 299 | 2,241 | 22,528 | 0 |
| 46-implement | s3logs | implement |  |  | ec2 | $0.0951 | 46 | stop |  | 0 | 215,744 | 9,161 | 18,591 | 4,181,760 | 0 |
| 46-review-1 | s3logs | review | 1 |  | ec2 | $0.0112 | 5 | stop | PASS | 0 | 33,934 | 3,108 | 1,874 | 61,184 | 0 |
| 46-tests-1a | s3logs | tests | 1a |  | ec2 | $0.0112 | 5 | stop | PASS | 0 | 28,938 | 4,984 | 1,799 | 55,040 | 0 |
| 46-tests-1b | s3logs | tests | 1b |  | ec2 | $0.0160 | 7 | stop | PASS | 0 | 23,907 | 828 | 13,986 | 135,680 | 0 |
| 46-idiom-1 | s3logs | idiom | 1 |  | ec2 | $0.0184 | 6 | stop | PASS | 0 | 38,072 | 1,027 | 12,986 | 117,120 | 0 |

## 6. AWS infrastructure cost (non-model spend)

The $19.86 above is **model API spend only**. Running the loop also used AWS infrastructure for the EC2-hosted batches (issues 8–46). Reconstructed from `terraform.tfstate`, EC2/EBS describe calls and AWS published on-demand pricing (eu-central-1 / Frankfurt), 2026 rates:

| Resource | Detail | Rate | Hours | Cost |
|---|---|---:|---:|---:|
| EC2 instance | t3.large (2 vCPU / 8 GiB), AL2023 | $0.096/hr | 127.62 | $12.25 |
| EBS root volume | 30 GB gp3, encrypted | $0.08/GB-mo | 127.62 | $0.42 |
| NAT gateway | 1 NAT gateway, 1 AZ | $0.052/hr | 127.62 | $6.64 |
| Secrets Manager interface endpoint | 1 AZ | $0.012/hr | 127.62 | $1.53 |
| Elastic IP (in-use) | 1 address for the NAT gateway | $0.005/hr | 127.62 | $0.64 |
| **Subtotal (compute + network)** | | | | **$21.48** |

- Instance window: launched 2026-08-27T13:44:04Z, stopped 2026-09-01T21:21:14Z (user-initiated) = **127.62 h / 5.32 d**.
- NAT/endpoint/EIP were provisioned for the whole window; exact `PutObject`/data volumes are not itemised here.
- ECR image registry, S3 bucket and Secrets Manager secrets are effectively free at this scale and not itemised.

## 7. Combined total

| Component | Cost |
|---|---:|
| Model spend (this report's headline) | $19.86 |
| AWS infrastructure (compute + network, §6) | $21.48 |
| **Combined** | **$41.34** |

> The $21.48 infra line is an estimate from published on-demand rates; the instance was stopped rather than terminated, so a small ongoing EBS charge persists. Human oversight time is excluded.

## 8. Caveats & data notes

- **Issues 1–7 exist only in local logs**, not S3 — the S3 bucket records issues 8–46. This report merges both sources. The EC2 cost here is taken from the authoritative `run.log` ledger (`$17.8682`, all attempts), which is the true total; the harness's own `loop.out` anchor (`$16.42 in logs all told`) undercounts because it sums only surviving `*.json` (see next bullet).
- **Re-attempted issues overwrite their log files.** Issue #27 was attempted 4 times; the first 3 attempts' `*.json`/`*.jsonl` (27 invocations, ~$1.45) were overwritten on S3 by the final successful attempt. Their **cost is recovered from the `run.log` ledger**, but their per-step **token data is lost** (files gone) — so issue #27's token row covers only its final attempt, while its cost covers all four. Issues #28 and #40 each had one abandoned attempt whose files were also overwritten; both are fully recovered in cost, and their final attempts carry the surviving token data.
- **Issue #8 was worked twice**: a local NO_PUSH smoke test (container-run, $0.1556) and the EC2 run that actually landed it. Both are counted in the grand total; the redundant smoke test inflates issue #8 by $0.16 and adds one extra `implement`.
- **`total_cost_usd` = sum of step `cost`s** the provider reported (cache discounts included). `total` tokens in a step = input + output + cache.read (the running-context re-read).
- **`cache.write` is 0 across the build** — the provider reported no cache writes, only cache reads.
- A few invocations returned `no verdict in the output — failing closed` (`$0` cost, FAIL, 1 finding "no verdict returned"). They are real failures (a crashed/timeout invocation), not free work.
- Base commit for each issue is the tree it started from; landed commit SHAs (from the GitHub history) are in the per-issue breakdown below if needed. Gate runs (deterministic, no model) cost nothing and are not listed.

## 9. Machine-readable source

This report is derived from:
- `logs/` — local harness runs (issues 1–8).
- S3: `s3://archunitdev-logs-…/loop/20260831T214650Z/` — EC2 runs (issues 8–46): 373 `.jsonl`, 700 `.json`, 41 `issue-*.md`, 170 `.txt`.
- The per-invocation CSV (issue, tag, role, round, retry, source, cost, turns, reason, verdict, findings, in/out/reasoning/cache tokens) is regenerable from the same data.

---

*Report generated 2026-09-23. Model spend is the source of truth for cross-model comparison (opus-5 run should reuse the identical loop + log layout).*

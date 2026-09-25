# ArchUnitSharp, built twice: deepseek-v4-flash vs Claude Opus 5.5

The same 46-issue backlog, built from the same starting commit by the same ArchUnitDev loop, once with
`deepseek-v4-flash` (via opencode-go) and once with Claude Opus 5.5 on Amazon Bedrock. Each model did
everything in its own build: implementing, all three critics, and every fix.

Sources: [`ArchUnitSharp-build-report.md`](ArchUnitSharp-build-report.md) (deepseek-v4-flash) and
[`ArchUnitSharpTest-opus-5-5-report.md`](ArchUnitSharpTest-opus-5-5-report.md) (Opus 5.5). §3's tables
come from `report/compare_reports.py`, and the rest from the sources given in each section.

## 1. Headline

| | deepseek-v4-flash | Opus 5.5 |
|---|---:|---:|
| Issues landed | 45 of 46 | 45 of 46 |
| Model spend | **$19.86** | **$346.70** (17.5×) |
| AWS infrastructure (estimate) | $21.48 | $13.27 |
| **Combined** | **$41.34** | **$359.98** (8.7×) |
| Model spend per landed issue | $0.44 | $7.70 |
| Issues abandoned at least once | 5 (#1, #7, #27, #28, #40) | 2 (#38, #39) |
| Landed on the first attempt | 40 | 43 |
| Loop wall clock | issues closed 2026-08-25 → 09-01, with the EC2 host up 127.6 h over several batches | 18.4 h running (15.0 h benchmark + 3.4 h relaunch), within a 28.8 h window |
| Tests in the finished suite (all passing, none skipped) | 1,852 | 1,534 |

Both builds reached the same place: every issue but `#44` (Publish to NuGet, held back by hand in both)
landed, and the finished suite is green. Opus 5.5 cost 17.5× as much in model spend, and 18.1× per
issue at the median. It abandoned fewer issues, took fewer turns (4,033 against 7,183) and wrote about
half the output tokens, but each turn cost 31× as much.

## 2. What was held constant, and what was not

**The same:**

- **The loop.** `run.sh`, `gate/csharp.sh`, `prompts/csharp/`, `opencode/` and `schema/` last changed
  in `1f49278` on 2026-08-26. Every deepseek EC2 batch (`#8` onward) and the whole Opus build ran that
  exact harness. Only the image's `Dockerfile.csharp` was added afterwards, and it changes how the
  harness is packaged, not what it does.
- **The starting point.** Both target repos grow from the same root commit with the same `AGENTS.md`
  and the same issue texts.
- **The variant** is `VARIANT=high` in both. So is the round budget: 3 rounds per attempt, one
  re-attempt of an abandoned issue on the batch's final tree, and the double test critic in round 1.

**Different:**

| | deepseek-v4-flash | Opus 5.5 |
|---|---|---|
| Model / provider | `opencode-go/deepseek-v4-flash` | `amazon-bedrock/us.anthropic.claude-opus-5-5` (US geographic inference profile) |
| Host | 1 × t3.large, eu-central-1, plus the `#1`-`#8` bring-up run locally | 2 × m5.xlarge, us-east-1 (one ran the loop, one on standby) |
| Per-invocation timeout | not recorded in its report | 60m (240m for the relaunch) |
| Harness for `#1`-`#7` | the bring-up harness, before `1f49278` hardened verdict extraction and timeouts | the final harness |
| Abandoned issues | re-attempted by the normal `RETRY_ABANDONED` pass, or on a later batch | `#38`/`#39` re-run by a manual relaunch (15 rounds, 240m, findings carried), because the abandon breaker had ended the run before the retry pass ([`deploy/runs/README.md`](deploy/runs/README.md#the-24-september-brute-force-archunitsharptest-38-and-39-on-opus-55)) |

**The critics are the model too.** Every PASS in a build was given by that build's own model. "Landed"
means the model's own review was satisfied, not that one independent bar was met twice. That makes §4
the fairer comparison of output, and §3's rounds and abandonments a measure of how each model's
implementer did against its own critics.

## 3. The numbers side by side

### Totals

| Metric | deepseek-v4-flash | Opus 5.5 | Opus 5.5 ÷ deepseek-v4-flash |
|---|---:|---:|---:|
| Issues landed | 45 of 46 | 45 of 46 | — |
| Total model spend | $19.8640 | $346.7049 | 17.45× |
| Model invocations | 511 | 443 | 0.87× |
| Implement invocations | 54 | 47 | 0.87× |
| Total model turns | 7,183 | 4,033 | 0.56× |
| Tokens — input | 27,923,369 | 8,938 | 0.00× |
| Tokens — output | 9,738,714 | 4,400,320 | 0.45× |
| Tokens — reasoning | 1,425,257 | 0 | — |
| Tokens — cache read | 583,483,008 | 382,817,736 | 0.66× |
| Tokens — cache write | 0 | 30,116,119 | — |
| Total findings raised by critics | 127 | 140 | 1.10× |
| Critic verdicts — pass / fail | 264 / 109 | 251 / 93 | — |
| Tokens — everything sent (input + cache read + cache write) | 611,406,377 | 412,942,793 | 0.68× |
| Cost per landed issue | $0.4414 | $7.7046 | 17.45× |
| Cost per model turn | $0.002765 | $0.085967 | 31.09× |

### Rounds to land

The highest review round each landed issue reached, across all its attempts (1 = the first implementation passed).

| Rounds | deepseek-v4-flash | Opus 5.5 |
|---:|---:|---:|
| 1 | 15 | 12 |
| 2 | 15 | 20 |
| 3 | 7 | 9 |
| 4 | 8 | 4 |
| **landed on the first attempt** | **40** | **43** |
| abandoned at least once | 5 (#1, #7, #27, #28, #40) | 2 (#38, #39) |

Per-issue cost ratio (Opus 5.5 ÷ deepseek-v4-flash) over the 45 issues both landed: median **18.1×**, lowest 3.2× (#45), highest 70.1× (#9).

### Per issue

| # | Issue | deepseek-v4-flash $ | Opus 5.5 $ | ratio | deepseek-v4-flash rounds | Opus 5.5 rounds | deepseek-v4-flash attempts | Opus 5.5 attempts |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | Kernel: Edge, Graph and ImportKind | $0.3227 | $3.7816 | 11.7× | 4 | 2 | 2 | 1 |
| 2 | Kernel: pattern matching — globs, regex and match targets | $0.1771 | $4.1557 | 23.5× | 2 | 2 | 1 | 1 |
| 3 | Kernel: RegexFactory and the matcher factories | $0.1133 | $2.9490 | 26.0× | 1 | 2 | 1 | 1 |
| 4 | Kernel: Violation base type and EmptyTestViolation | $0.1201 | $2.2181 | 18.5× | 2 | 2 | 1 | 1 |
| 5 | Kernel: CheckOptions and the Checkable contract | $0.1999 | $3.1613 | 15.8× | 3 | 3 | 1 | 1 |
| 6 | Kernel: TechnicalError and UserError | $0.0587 | $1.4304 | 24.4× | 2 | 1 | 1 | 1 |
| 7 | Extraction: locate the project and enumerate source files | $0.8483 | $6.0353 | 7.1× | 4 | 3 | 3 | 1 |
| 8 | Extraction: parse imports and resolve them to targets | $0.5086 | $5.2216 | 10.3× | 3 | 2 | 2 | 1 |
| 9 | Extraction: classify internal vs external dependencies | $0.1097 | $7.6925 | 70.1× | 2 | 3 | 1 | 1 |
| 10 | Extraction: self-edges and parallel-edge merging | $0.1011 | $2.2566 | 22.3× | 1 | 1 | 1 | 1 |
| 11 | Extraction: graph cache and clear-graph-cache | $0.2377 | $4.1396 | 17.4× | 2 | 2 | 1 | 1 |
| 12 | Extraction: per-line ignore directive | $0.2082 | $5.8108 | 27.9× | 1 | 2 | 1 | 1 |
| 13 | Projection: project edges, nodes and cycles | $0.3673 | $5.7342 | 15.6× | 2 | 2 | 1 | 1 |
| 14 | Projection: the per-edge MapFunctions | $0.0903 | $1.3854 | 15.3× | 1 | 1 | 1 | 1 |
| 15 | Projection: cycle detection — Tarjan and Johnson | $0.0743 | $3.5465 | 47.7× | 1 | 2 | 1 | 1 |
| 16 | Files API: entry point and selectors | $0.1964 | $5.6622 | 28.8× | 1 | 3 | 1 | 1 |
| 17 | Files API: should and should not | $0.2293 | $3.0941 | 13.5× | 2 | 1 | 1 | 1 |
| 18 | Files API: have no cycles | $0.2472 | $6.9039 | 27.9× | 1 | 2 | 1 | 1 |
| 19 | Files API: have name, be in folder, be in path | $0.1604 | $3.3243 | 20.7× | 1 | 2 | 1 | 1 |
| 20 | Files API: depend on files | $0.4638 | $11.4748 | 24.7× | 3 | 4 | 1 | 1 |
| 21 | Files API: depend on external modules | $0.2424 | $9.8931 | 40.8× | 1 | 2 | 1 | 1 |
| 22 | Files API: adhere to — custom user predicate | $0.2420 | $9.5738 | 39.6× | 1 | 2 | 1 | 1 |
| 23 | The empty-test guard on every terminal | $0.1793 | $2.4996 | 13.9× | 2 | 1 | 1 | 1 |
| 24 | Testing: violation formatting, result shaping and colour | $0.1861 | $3.3407 | 18.0× | 1 | 2 | 1 | 1 |
| 25 | Testing: the framework-agnostic assert helper | $0.1419 | $2.1134 | 14.9× | 1 | 1 | 1 | 1 |
| 26 | Testing: native integration with xUnit, with NUnit and MSTest covered by the agnostic path | $0.4714 | $4.2031 | 8.9× | 2 | 2 | 1 | 1 |
| 27 | Layers API | $2.9458 | $13.4035 | 4.6× | 4 | 2 | 1 | 1 |
| 28 | Graph reports: the snapshot and its query options | $1.5213 | $13.1901 | 8.7× | 4 | 2 | 2 | 1 |
| 29 | Graph reports: the six output formats | $0.2924 | $9.0935 | 31.1× | 1 | 2 | 1 | 1 |
| 30 | Slices API: slicing projections and forbidden dependencies | $0.8393 | $15.8097 | 18.8× | 2 | 3 | 1 | 1 |
| 31 | Slices API: PlantUML component diagrams | $0.8136 | $13.6110 | 16.7× | 3 | 4 | 1 | 1 |
| 32 | Metrics: extraction and count metrics | $1.1169 | $12.6229 | 11.3× | 4 | 3 | 1 | 1 |
| 33 | Metrics: the LCOM family | $0.7776 | $8.8829 | 11.4× | 4 | 2 | 1 | 1 |
| 34 | Metrics: distance metrics and the zone checks | $0.8777 | $15.8546 | 18.1× | 4 | 3 | 1 | 1 |
| 35 | Metrics: custom metrics | $0.4778 | $7.6665 | 16.0× | 3 | 1 | 1 | 1 |
| 36 | Metrics: threshold verbs | $0.1784 | $9.2814 | 52.0× | 2 | 3 | 1 | 1 |
| 37 | Metrics: HTML report export | $0.3485 | $9.0735 | 26.0× | 1 | 1 | 1 | 1 |
| 38 | Pattern exclusions — the `except` companion | $0.5161 | $33.0926 | 64.1× | 2 | 4 | 1 | 2 |
| 39 | Logging | $0.8777 | $34.7203 | 39.6× | 3 | 4 | 1 | 2 |
| 40 | Dogfood: enforce our own architecture rules on ourselves | $0.6146 | $5.6258 | 9.2× | 4 | 2 | 2 | 1 |
| 41 | README someone can actually start from | $0.2767 | $5.4045 | 19.5× | 2 | 1 | 1 | 1 |
| 42 | Documentation site on GitHub Pages | $0.3212 | $13.8553 | 43.1× | 2 | 3 | 1 | 1 |
| 43 | CI: build, test and lint on every push | $0.3930 | $1.2908 | 3.3× | 3 | 1 | 1 | 1 |
| 44 | Publish to NuGet | — | — | — | — | — | — | — |
| 45 | Restore the full test suite to green across the CI matrix | $0.2259 | $0.7226 | 3.2× | 2 | 1 | 1 | 1 |
| 46 | Prevent Metrics<T>() from silently passing without analyzing the target type | $0.1519 | $1.9018 | 12.5× | 1 | 1 | 1 | 1 |

## 4. What each build produced

Measured on each repository's final `main`: ArchUnitSharp `7aee9c3` (deepseek) and ArchUnitSharpTest
`fa896d9` (Opus). The test counts come from running `dotnet test ArchUnitSharp.sln -c Release` for both,
in the same container image, on 2026-09-25.

| | deepseek-v4-flash | Opus 5.5 |
|---|---:|---:|
| Tests run / passed / skipped | 1,852 / 1,852 / 0 | 1,534 / 1,534 / 0 |
| Test projects | 12 | 11 |
| `[Fact]` / `[Theory]` / `[InlineData]` | 1,811 / 9 / 41 | 969 / 103 / 518 |
| Source `.cs` files / lines (`src/`) | 160 / 18,004 | 181 / 18,743 |
| Test `.cs` files / lines (`tests/`) | 152 / 24,350 | 123 / 20,904 |
| Markdown lines (every `.md`: README, docs, NOTES, AGENTS) | 1,645 | 2,407 |
| Commits (one per landed issue, plus the root) | 46 | 46 |
| CI on the final commit | `ci` passes: build, `dogfood`, and tests on ubuntu, windows and macOS. `docs` fails at "Get Pages site: Not Found", because GitHub Pages is not enabled on the repository; nothing in the code causes it | "Build, lint and test" and "Build the site" pass; "Publish to GitHub Pages" is skipped |

The two libraries are about the same size, 18.0k and 18.7k lines of source. They test differently.
deepseek wrote one `[Fact]` per case: 1,811 of them, and 24.4k lines of test code. Opus wrote a third
as many facts and 11× as many `[Theory]` methods, and fed them 518 `[InlineData]` rows: fewer tests,
in fewer lines. Neither count says which suite catches more bugs. Measuring that would take a
mutation-testing run against both, and neither build has had one. Opus also wrote 46% more Markdown.

## 5. Where the Opus money went

Opus's dollar figure is not just the harness's own arithmetic. The logged tokens, priced at Bedrock's
published us-east-1 on-demand rates for Claude Opus 5.5, come to **$346.70**, matching the ledger to the
cent. The rates are the "Standard" (non-global) tier, the tier for a `us.` profile, fetched from the AWS
Price List API on 2026-09-25: input $4.40/M, output $22.00/M, cache read $0.22/M, cache write $5.50/M.

| Token type | Tokens | Cost | Share |
|---|---:|---:|---:|
| Cache write | 30,116,119 | $165.64 | 47.8% |
| Output | 4,400,320 | $96.81 | 27.9% |
| Cache read | 382,817,736 | $84.22 | 24.3% |
| Input | 8,938 | $0.04 | 0.0% |
| **Total** | | **$346.70** | |

- **Cache writes are the biggest line.** Every invocation starts a fresh opencode session, so each one
  writes its prompt and the growing context into the cache from scratch: 30M tokens at 25× the cache
  read rate. deepseek-v4-flash reported no cache writes at all. It was charged only for reading.
- **The `global.` profile would have cost 10% less.** At the Global tier's rates ($4.00 / $20.00 /
  $0.20 / $5.00 per M) the same tokens come to $315.19.
- **CloudWatch agrees with the logs.** Bedrock's own counts for the model over the run window are 3-5%
  above the harness's (see the Opus report's §8). The gap is requests the loop did not log: the three
  implement calls that crashed before their first turn, and diagnostic calls made outside the loop.
- **Cost Explorer has not posted the run yet.** A day after it finished, the account shows neither the
  EC2 hosts nor the model, so the bill cannot confirm this yet. Regenerate the Opus report once it posts.

deepseek-v4-flash's dollars are opencode's per-token pricing for `opencode-go/deepseek-v4-flash`. That
run had no bill or provider-side cross-check, so its $19.86 carries less evidence than Opus's $346.70.

## 6. Reading the differences

- **On this backlog, the cheap model was enough.** deepseek-v4-flash landed the same 45 issues for
  about a seventeenth of the model spend, and its finished library is the same size with a larger,
  green suite. If the question is "can this loop build this library unattended", both answered yes,
  and deepseek's answer cost $41 all in.
- **Opus needed less correction.** It abandoned 2 issues to deepseek's 5, landed 43 first time to 40,
  and reached round 4 on 4 issues to deepseek's 8. It got there in 44% fewer turns with 55% fewer output
  tokens, and needed fewer fix rounds even though its critics were Opus too.
- **The two hardest issues were not the same ones.** deepseek struggled on the early kernel and
  extraction issues (`#1`, `#7`) and the Layers and Graph reports features (`#27`, `#28`). Opus struggled
  on `#38` (pattern exclusions) and `#39` (logging), which deepseek landed in 2 and 3 rounds for under
  $1.40 together. Opus's critics kept both open on findings such as a doc example the folder rules
  contradict, and a `Release(fullPath)` whose deletion no test catches. Each issue landed on its first
  relaunched attempt, in 2 rounds.
- **The ratio is not flat, and rounds explain most of it.** Across the 45 issues it runs from 3.2×
  (`#45`) to 70.1× (`#9`), with a median of 18.1×. Eight issues are above 39× (`#9`, `#15`, `#21`,
  `#22`, `#36`, `#38`, `#39`, `#42`), and on every one Opus went at least one round further than
  deepseek. Seven are under 10× (`#7`, `#26`, `#27`, `#28`, `#40`, `#43`, `#45`). On all of them but
  `#26`, where the two were level, deepseek went further. A round costs Opus a full implement-sized
  context written to the cache again, so an extra round is where the price per token shows.
- **Infrastructure is the one line where Opus was cheaper.** Its $13.27 against deepseek's $21.48
  reflects a shorter window, not cheaper hosts: m5.xlarge costs twice as much per hour as t3.large, but
  the Opus build was up for 29 h and the deepseek host for 128 h. At deepseek's model prices,
  infrastructure is half the total; at Opus's, it is 4%.

## 7. Caveats

- **The two builds ran a month apart,** in different regions on different instance types. Neither
  affects the model's output, but both affect wall clock and the infrastructure line.
- **deepseek's `#1`-`#7` ran on the bring-up harness.** `1f49278` was written from `#7`'s run and
  hardened verdict extraction and timeouts, and `22eca2e` fixed verdict extraction before it. So some
  of the abandonments of `#1` and `#7` may have been the harness's rather than the model's.
- **deepseek's `#27`, `#28` and `#40` had earlier attempts overwritten.** Their costs are recovered
  from the ledger, but their token and turn counts cover only the final attempt, so deepseek's totals
  of 7,183 turns and 611M tokens sent are undercounts. Opus's are complete.
- **Opus reports 0 reasoning tokens.** Bedrock does not report Anthropic's thinking separately, so
  compare output tokens, not reasoning.
- **Opus's `#38`/`#39` relaunch ran outside the benchmark settings** (15 rounds and 240m rather than 3
  and 60m) and cost $30.94 of the total. Each issue used 2 of its 15 rounds and no invocation came near
  the timeout, so the relaunch gave them a second attempt, not more of anything the benchmark lacked.
- **The Opus build lost three $0 attempts** to an opencode crash on the first invocation in a fresh
  container. They are excluded from every count here, and cost nothing but wall clock.
- **Tests counted, not tests' strength.** §4 counts tests; it does not measure how many bugs they would
  catch.

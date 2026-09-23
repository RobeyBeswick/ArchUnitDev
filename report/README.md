# report/

Tooling that turns the ArchUnitDev harness logs into a granular, machine-readable
build cost report — the data feed for comparing a model's cost/token efficiency
across target languages (e.g. the C# / deepseek-v4-flash run vs an opus-5 run).

## What it produces

`ArchUnitSharp-build-report.md` (regenerable) with:

- grand totals: model spend, per-issue cost, invocation/turn counts, token
  totals split by input / output / reasoning / cache-read / cache-write
- a per-issue table (46 rows) with cost, rounds, attempts and tokens
- a per-invocation table (every `issue-role[-round]` model call with cost,
  turns, verdict, findings and token counts)
- the abandoned / re-attempted issues with the cost of every attempt
- an AWS infrastructure cost section separate from model spend

## Usage

```bash
# 1. Stage an EC2 log prefix (all its .json/.jsonl/.txt/md files) locally:
aws s3 sync s3://<bucket>/loop/<RUN_ID> ./s3logs

# 2. Regenerate the report (local logs default to logs/csharp* + logs/container-run):
python3 report/gen_report.py \
    --s3-logs ./s3logs \
    --out ArchUnitSharp-build-report.md \
    --repo RobeyBeswick/ArchUnitSharp
```

Config via flags or env: `--local-logs`/`LOCAL_LOGS`, `--s3-logs`/`S3_LOGS`,
`--out`/`OUT`, `--repo`/`TARGET_REPO`.

## Data layout it reads (what the loop logs)

Each model invocation writes, under a `logs/` directory:

- `<issue>-<role>[-<round>][a|b].json` — synthesized envelope:
  `total_cost_usd`, `num_turns`, `terminal_reason`, `result`
- `<issue>-<role>[-<round>][a|b].jsonl` — raw opencode NDJSON, one
  `step_finish` per model step carrying `tokens{input,output,reasoning,cache}`
  and `cost` (USD)
- `<issue>-<role>-<round>.verdict.json` — critic verdict + findings
- `issue-<n>.md` — the issue description
- `run.log` — the authoritative per-invocation cost ledger
- `loop.out` — run narration

## Important caveats

- **Re-attempted issues overwrite their files.** A later attempt of the same
  issue reuses the same tag names, so earlier attempts' `.json`/`.jsonl` are
  overwritten on S3. This script recovers those attempts' **cost** from
  `run.log` (the ledger), but their per-step **token data is unrecoverable**.
  See §8 of the generated report.
- `total_cost_usd` = sum of provider step costs (cache discounts included).
- `cache.read` tokens are the running-context re-reads on every step — billed
  at the cache-discount rate, which is why they dwarf input/output yet cost
  little.
- Gate runs are deterministic (no model) and cost nothing; they are not listed.
# report/

Tooling that turns the ArchUnitDev harness logs into a granular, machine-readable
build cost report — the data feed for comparing a model's cost/token efficiency
across target languages (e.g. the C# / deepseek-v4-flash run vs an opus-5 run).

## What it produces

A markdown report (regenerable) with:

- grand totals: model spend, per-issue cost, invocation/turn counts, token
  totals split by input / output / reasoning / cache-read / cache-write
- a per-issue table (one row per issue) with status, cost, rounds, attempts and tokens
- a per-invocation table (every `issue-role[-round]` model call with cost,
  turns, verdict, findings and token counts)
- the abandoned / re-attempted issues with the cost of every attempt
- an AWS infrastructure cost section separate from model spend, itemised from
  an `--infra` file
- optional cross-checks against AWS: Bedrock's CloudWatch token counts for the
  run window, and Cost Explorer's account-wide bill by service
- caveats computed from the data (overwritten attempts, cache writes, zero
  reasoning, fail-closed critics, a run still in progress)

The model, variant, run window, abandonments and re-attempts are all read from
`run.log`; nothing run-specific is hard-coded. The report prints labels, never
local paths, because it is committed to a public repository.

## Usage

```bash
# 1. Stage an EC2 log prefix (all its .json/.jsonl/.txt/md files) locally:
aws s3 sync s3://<bucket>/loop/<RUN_ID> ./s3logs

# 2. Regenerate the report:
python3 report/gen_report.py \
    --s3-logs ./s3logs --s3-uri s3://<bucket>/loop/<RUN_ID> \
    --repo RobeyBeswick/ArchUnitSharpTest \
    --infra report/infra-opus-5-5-bedrock.json \
    --cloudwatch-model us.anthropic.claude-opus-5-5 --cost-explorer \
    --out ArchUnitSharpTest-opus-5-5-report.md
```

Config via flags or env: `--local-logs`/`LOCAL_LOGS` (optional; bring-up runs
to merge in), `--s3-logs`/`S3_LOGS`, `--out`/`OUT`, `--repo`/`TARGET_REPO`.
`--s3-uri` is only a label for the sources section; shorten the bucket name in
anything you commit.

`--s3-logs` takes a comma-separated list when one build's logs are split across
directories — the Opus 5.5 build's brute-force attempts each ran as their own
`run.sh` with their own log directory:

```bash
D=./s3logs
python3 report/gen_report.py --s3-logs "$D,$D/bruteforce/38-attempt-1,$D/bruteforce/39-attempt-1" …
```

The first directory is the primary one; the others are labelled relative to it,
and the ledger is the sum of every directory's `run.log`.

## Comparing two builds

`compare_reports.py` reads the grand-totals and per-issue tables of two reports
of the same backlog and prints markdown tables side by side: the totals with
their ratio, the rounds each issue took to land, and every issue's cost in both
builds. It reads reports rather than logs, because the report is the one
artefact both builds have.

```bash
python3 report/compare_reports.py ArchUnitSharp-build-report.md ArchUnitSharpTest-opus-5-5-report.md \
    --labels deepseek-v4-flash "Opus 5.5"
```

`ArchUnitSharp-deepseek-v4-flash-vs-opus-5-5.md` puts those tables inside the written comparison.

The S3 logs are the source of truth for cost: `run.log` is the ledger, and the
`.jsonl` files carry the tokens. The AWS cross-checks use the ambient
credentials (`AWS_PROFILE`), bound every call with `--cli-read-timeout 60`, and
leave their section out with a warning if a call fails. Cost Explorer lags
usage by up to a day and is account-wide.

## Infrastructure files

`infra-<run>.json` itemises one run's hosts:

```json
{"hours": null, "note": "…", "rows": [
  {"resource": "EC2 instances", "detail": "…", "count": 2, "rate": 0.192, "unit": "hr"},
  {"resource": "EBS root volumes", "detail": "…", "count": 60, "rate": 0.08, "unit": "GB-Mo"}]}
```

A row costs `count × rate × hours`, and a `GB-Mo` rate is divided by 730 h.
`"hours": null` means the run window from `run.log`. Give a number to bill the
hosts' actual uptime instead. `infra-deepseek-v4-flash.json` reproduces the
first report's $21.48; `infra-opus-5-5-bedrock.json` covers the Opus 5.5
benchmark in us-east-1.

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
- `loop.out` — run narration (read only when a dir has no `run.log`, since it
  repeats every `run.log` line)
- `skipped` — issues held back or abandoned

## Important caveats

- **Re-attempted issues overwrite their files.** A later attempt of the same
  issue reuses the same tag names, so earlier attempts' `.json`/`.jsonl` are
  overwritten on S3. This script recovers those attempts' **cost** from
  `run.log` (the ledger), but their per-step **token data is unrecoverable**.
  The generated report says so only when it happened.
- `total_cost_usd` = sum of provider step costs (cache discounts included).
- `cache.read` tokens are the running-context re-reads on every step — billed
  at the cache-discount rate, which is why they dwarf input/output yet cost
  little.
- Gate runs are deterministic (no model) and cost nothing; they are not listed.
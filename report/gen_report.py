#!/usr/bin/env python3
"""Generate a granular cost/token build report from ArchUnitDev harness logs.

Aggregates per-issue and per-invocation cost + token data from the loop's
`logs/` directory (the same layout run.sh writes locally and log-sync.sh ships
to S3). Reads any mix of:

  * local bring-up runs (--local-logs; optional — an EC2-only run has none)
  * an EC2 log dir synced from S3 (--s3-logs)

Everything that differs between runs is read from the logs or passed in, not
written into this script: the model and variant come from run.log, the
abandonments and re-attempts from run.log's narration, the infrastructure from
an --infra JSON file. The first version hard-coded all three from the
deepseek-v4-flash run, and pointed at the Opus 5.5 run it reported #1 and #7 as
abandoned and a t3.large in Frankfurt that run never used.

Costs for re-attempted issues are reconciled against the authoritative
`run.log` ledger, because an attempt in a *later run* reuses the tag names of
an earlier one and overwrites its `*.json`/`*.jsonl` (see Caveats in the
generated report).

Usage:
    aws s3 sync s3://<bucket>/loop/<RUN_ID> ./s3logs
    python3 report/gen_report.py \
        --s3-logs ./s3logs --s3-uri s3://<bucket>/loop/<RUN_ID> \
        --repo RobeyBeswick/ArchUnitSharpTest \
        --infra report/infra-opus-5-5-bedrock.json \
        --cloudwatch-model us.anthropic.claude-opus-5-5 --cost-explorer \
        --out ArchUnitSharpTest-opus-5-5-report.md

Environment overrides:
    LOCAL_LOGS   comma-separated dirs
    S3_LOGS      EC2 log dir
    OUT          output markdown path
    TARGET_REPO  GitHub repo for issue metadata

The AWS cross-checks (--cloudwatch-model, --cost-explorer) shell out to the aws
CLI with the ambient credentials (AWS_PROFILE); each call is bounded, and a
failure omits its section with a warning rather than failing the report.

Requires: python3; `gh` for live issue metadata; the aws CLI for the cross-checks.
"""
import json, os, re, sys, glob, subprocess
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\s")
MODEL_RE = re.compile(r"model (\S+) \(implement/critics\), (\S+) \(fix/retro\), variant (\S+),")
LEDGER_RE = re.compile(r"^\S+\s+(\d+)-([a-z0-9-]+): .*cost=\$([0-9.]+)")
ABANDON_RE = re.compile(r"#(\d+) ABANDONED")
RETRY_LANDED_RE = re.compile(r"#(\d+) landed on the re-attempt")
PUSHED_RE = re.compile(r"#(\d+) (?:pushed as|committed locally as) ([0-9a-f]{7,})")
START_RE = re.compile(r"=== issue #(\d+)(?: RE-ATTEMPT)?:")
FAILED_CLOSED_RE = re.compile(r"no verdict in the output — failing closed")


def env_list(name, default):
    return [d for d in (os.environ.get(name) or default).split(",") if d]


def narration(d):
    """The run's narration for one log dir. run.log if present, else loop.out — never both, because
    loop.out is the container's stdout and repeats every line of run.log, which would double every
    abandonment count."""
    for name in ("run.log", "loop.out"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            with open(p, encoding="utf-8", errors="replace") as f:
                return f.read().splitlines()
    return []


def aws(args, timeout=90):
    """One bounded aws CLI call returning parsed JSON, or None with a warning."""
    cmd = ["aws"] + args + ["--cli-read-timeout", "60", "--output", "json"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=True)
        return json.loads(r.stdout)
    except Exception as e:
        err = getattr(e, "stderr", "") or str(e)
        print(f"aws {' '.join(args[:2])} failed: {err.strip()[:300]}", file=sys.stderr)
        return None


def cloudwatch_tokens(model_id, region, start, end):
    """Bedrock's own per-model counts over [start, end]. Period 300s in chunks of at most 1440
    datapoints (5 days), so the window starts at the run's first minute and not at an hour boundary
    that would sweep in smoke-test calls made just before the launch."""
    metrics = ["Invocations", "InputTokenCount", "OutputTokenCount",
               "CacheReadInputTokenCount", "CacheWriteInputTokenCount"]
    out = {}
    for m in metrics:
        total, t = 0.0, start
        while t < end:
            t2 = min(end, t + timedelta(days=5))
            j = aws(["cloudwatch", "get-metric-statistics", "--region", region,
                     "--namespace", "AWS/Bedrock", "--metric-name", m,
                     "--dimensions", f"Name=ModelId,Value={model_id}",
                     "--start-time", t.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "--end-time", t2.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "--period", "300", "--statistics", "Sum"])
            if j is None:
                return None
            total += sum(p["Sum"] for p in j.get("Datapoints", []))
            t = t2
        out[m] = int(total)
    return out


def cost_explorer(start, end):
    """Account-wide unblended cost by service over the run's UTC days (Cost Explorer's finest
    useful granularity; it lags the usage by up to a day)."""
    s = start.date().isoformat()
    e = (end.date() + timedelta(days=1)).isoformat()
    j = aws(["ce", "get-cost-and-usage", "--region", "us-east-1",
             "--time-period", f"Start={s},End={e}", "--granularity", "DAILY",
             "--metrics", "UnblendedCost", "--group-by", "Type=DIMENSION,Key=SERVICE"])
    if j is None:
        return None
    by = defaultdict(float)
    for day in j.get("ResultsByTime", []):
        for g in day.get("Groups", []):
            by[g["Keys"][0]] += float(g["Metrics"]["UnblendedCost"]["Amount"])
    return s, e, dict(by)


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--local-logs", help="comma-separated local log dirs (optional)")
    ap.add_argument("--s3-logs", help="EC2/S3 log dir (run.log + *.json/jsonl)")
    ap.add_argument("--s3-uri", help="the S3 prefix the dir was synced from, for the report's source list")
    ap.add_argument("--out", help="output markdown path")
    ap.add_argument("--repo", help="GitHub repo (default RobeyBeswick/ArchUnitSharp)")
    ap.add_argument("--infra", help="JSON file itemising the run's AWS infrastructure (see report/infra-*.json)")
    ap.add_argument("--cloudwatch-model", help="Bedrock model ID to cross-check token counts against CloudWatch")
    ap.add_argument("--cost-explorer", action="store_true", help="add Cost Explorer's by-service total for the run's days")
    ap.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "us-east-1"))
    a = ap.parse_args()

    LOCAL_DIRS = a.local_logs.split(",") if a.local_logs else env_list("LOCAL_LOGS", "")
    LOCAL_DIRS = [d for d in LOCAL_DIRS if os.path.isdir(d)]
    S3_DIR = a.s3_logs or os.environ.get("S3_LOGS") or os.path.join(REPO_ROOT, "s3logs")
    OUT = a.out or os.environ.get("OUT") or os.path.join(REPO_ROOT, "ArchUnitSharp-build-report.md")
    REPO = a.repo or os.environ.get("TARGET_REPO") or "RobeyBeswick/ArchUnitSharp"
    if not os.path.isdir(S3_DIR):
        sys.exit(f"S3 log dir not found: {S3_DIR}; pass --s3-logs (e.g. an `aws s3 sync` of a /loop/<RUN_ID> prefix)")
    ALL_DIRS = LOCAL_DIRS + [S3_DIR]
    # Labels, never paths: the report is committed to a public repository, and an absolute path
    # carries a username.
    def label(d):
        return "s3logs" if d == S3_DIR else os.path.basename(d.rstrip("/"))
    s3_label = a.s3_uri or "an S3 `/loop/<RUN_ID>` prefix"

    gh = fetch_issue_metadata(REPO)

    # ---- narration: models, window, attempts, abandonments, landings, held-back ----
    models, stamps = [], []
    abandoned = defaultdict(int)
    retry_landed, pushed, started = set(), {}, set()
    failed_closed = 0
    for d in ALL_DIRS:
        for line in narration(d):
            m = TS_RE.match(line)
            if m:
                stamps.append(datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc))
            m = MODEL_RE.search(line)
            if m and m.groups() not in models:
                models.append(m.groups())
            for rx, fn in ((ABANDON_RE, lambda n: abandoned.__setitem__(n, abandoned[n] + 1)),
                           (RETRY_LANDED_RE, retry_landed.add),
                           (START_RE, started.add)):
                m = rx.search(line)
                if m:
                    fn(int(m.group(1)))
            m = PUSHED_RE.search(line)
            if m:
                pushed[int(m.group(1))] = m.group(2)
            if FAILED_CLOSED_RE.search(line):
                failed_closed += 1
    held = set()
    for d in ALL_DIRS:
        p = os.path.join(d, "skipped")
        if os.path.exists(p):
            held |= {int(x) for x in open(p).read().split() if x.isdigit()}
    held -= started  # an abandoned issue lands in `skipped` too; only the never-attempted were held back
    run_start = min(stamps) if stamps else None
    run_end = max(stamps) if stamps else None
    run_hours = (run_end - run_start).total_seconds() / 3600 if stamps else 0.0

    # authoritative EC2 cost ledger from run.log (all attempts, incl. overwritten re-attempts)
    ledger = defaultdict(float)
    ledger_inv = ledger_impl = 0
    for line in narration(S3_DIR):
        m = LEDGER_RE.match(line.strip())
        if m:
            ledger[int(m.group(1))] += float(m.group(3))
            ledger_inv += 1
            if re.search(r"\d+-(?:retry-)?implement: rc=\d+ cost=", line):
                ledger_impl += 1
    print("run.log ledger EC2 total: $%.4f" % sum(ledger.values()), file=sys.stderr)

    # ---- parse invocation data ----
    TAG_RE = re.compile(r"^(\d+)-(.*)$")
    ROUND_RE = re.compile(r"^([a-z]+)(?:-(\d+)([ab]?))?$")

    def parse_role(rest):
        retry = False
        if rest.startswith("retry-"):
            retry = True
            rest = rest[len("retry-"):]
        m = ROUND_RE.match(rest)
        if not m:
            return rest, None, None, retry
        return m.group(1), m.group(2), m.group(3), retry

    def load_json_multi(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            content = f.read()
        try:
            return json.loads(content)
        except Exception:
            pass
        last = None
        for line in content.splitlines():
            line = line.strip()
            if not line: continue
            try:
                last = json.loads(line)
            except Exception:
                pass
        return last

    invocations = []
    for d in ALL_DIRS:
        for jf in glob.glob(os.path.join(d, "*.json")):
            tag = os.path.basename(jf)[:-5]
            if tag.endswith(".verdict"): continue
            m = TAG_RE.match(tag)
            if not m: continue
            issue = int(m.group(1)); rest = m.group(2)
            role, rnd, suffix, retry = parse_role(rest)
            try:
                j = json.load(open(jf, encoding="utf-8", errors="replace"))
            except Exception: continue
            vf = jf[:-5] + ".verdict.json"
            verdict = None; findings = 0
            if os.path.exists(vf):
                v = load_json_multi(vf)
                if v:
                    verdict = v.get("verdict"); findings = len(v.get("findings") or [])
            jlf = jf[:-5] + ".jsonl"
            toks = {"input":0,"output":0,"reasoning":0,"cache_read":0,"cache_write":0}
            if os.path.exists(jlf):
                for line in open(jlf, encoding="utf-8", errors="replace"):
                    line = line.strip()
                    if not line: continue
                    try: rec = json.loads(line)
                    except Exception: continue
                    if rec.get("type") == "step_finish":
                        t = (rec.get("part") or {}).get("tokens") or {}
                        toks["input"] += t.get("input") or 0
                        toks["output"] += t.get("output") or 0
                        toks["reasoning"] += t.get("reasoning") or 0
                        c = t.get("cache") or {}
                        toks["cache_read"] += c.get("read") or 0
                        toks["cache_write"] += c.get("write") or 0
            source = "local" if d in LOCAL_DIRS else "ec2"
            invocations.append({
                "tag": tag, "run": label(d), "issue": issue, "role": role, "round": rnd, "suffix": suffix,
                "retry": retry, "source": source, "cost": j.get("total_cost_usd") or 0,
                "turns": j.get("num_turns") or 0, "reason": j.get("terminal_reason") or "",
                "verdict": verdict, "findings": findings, "tokens": toks,
            })

    ROLE_ORDER = {"implement":0, "fix":1, "review":2, "tests":3, "idiom":4}
    invocations.sort(key=lambda x: (x["issue"], x["retry"], ROLE_ORDER.get(x["role"], 9),
        int(x["round"]) if x["round"] else 0, x["suffix"] or ""))

    # ---- per-issue aggregation ----
    per_issue = defaultdict(lambda: {"cost":0.0,"turns":0,"inv":0,"impl":0,
        "tokens":defaultdict(int),"verdicts":defaultdict(int),"findings":0,
        "rounds_max":0,"roles":defaultdict(int),"local":0.0,"ec2":0.0})
    for x in invocations:
        pi = per_issue[x["issue"]]
        pi["cost"] += x["cost"]; pi["turns"] += x["turns"]; pi["inv"] += 1
        if x["role"] == "implement": pi["impl"] += 1
        for k, v in x["tokens"].items(): pi["tokens"][k] += v
        if x["verdict"]: pi["verdicts"][x["verdict"]] += 1
        pi["findings"] += x["findings"]
        pi["roles"][x["role"]] += 1
        if x["round"]: pi["rounds_max"] = max(pi["rounds_max"], int(x["round"]))
        if x["source"] == "local": pi["local"] += x["cost"]
        else: pi["ec2"] += x["cost"]

    # Override EC2 cost with the authoritative ledger where it differs.
    overwritten = []
    for n in list(per_issue.keys()):
        if n in ledger and ledger[n] > per_issue[n]["ec2"] + 1e-6:
            overwritten.append((n, ledger[n] - per_issue[n]["ec2"]))
            per_issue[n]["ec2"] = ledger[n]
            per_issue[n]["cost"] = per_issue[n]["local"] + ledger[n]
            print(f"issue {n}: ec2 cost corrected -> {ledger[n]:.4f} (overwritten attempts recovered from run.log)", file=sys.stderr)

    grand = {"cost":0.0, "turns":0, "inv":0, "impl":0, "tokens":defaultdict(int),
             "verdicts":defaultdict(int), "findings":0, "local":0.0, "ec2":0.0}
    for n, pi in per_issue.items():
        for k in grand:
            if isinstance(grand[k], dict):
                for kk in pi[k]: grand[k][kk] += pi[k][kk]
            else:
                grand[k] += pi[k]

    # True invocation/implement counts: local = surviving json (complete); EC2 = ledger (all attempts).
    local_inv = sum(1 for x in invocations if x["source"] == "local")
    local_impl = sum(1 for x in invocations if x["source"] == "local" and x["role"] == "implement")
    grand["inv"] = local_inv + ledger_inv
    grand["impl"] = local_impl + ledger_impl
    rows_lost = grand["inv"] - len(invocations)

    # ---- status per issue ----
    def status(n):
        state = gh[n][1]
        if state == "CLOSED" and (n in per_issue or n in pushed):
            return "landed"
        if state == "CLOSED":
            return "closed (not by this run)"
        if n in pushed:
            return "landed (not pushed)"
        if n in held:
            return "held back"
        if n in per_issue or n in started:
            return "abandoned" if abandoned.get(n) and n not in retry_landed else "in progress"
        return "not attempted"
    issues_sorted = sorted(gh.keys())
    counts = defaultdict(int)
    for n in issues_sorted:
        counts[status(n)] += 1
    landed_n = counts["landed"] + counts["landed (not pushed)"]

    def f2(v): return f"{v:.2f}"
    def f4(v): return f"{v:.4f}"
    def f6(v): return f"{v:.6f}"
    def fmt(v): return f"{v:,}"
    def when(t): return t.strftime("%Y-%m-%d %H:%MZ") if t else "?"

    if len(models) == 1:
        mi, mf, var = models[0]
        model_line = (f"`{mi}` for implement, all three critics, fix and retro; `VARIANT={var}`. (No model split — one model for everything.)"
                      if mi == mf else f"`{mi}` for implement and the critics, `{mf}` for fix and retro; `VARIANT={var}`.")
    elif models:
        model_line = "several configurations across the runs merged here: " + "; ".join(
            f"`{mi}` / `{mf}`, variant `{var}`" for mi, mf, var in models)
    else:
        model_line = "not recorded in the narration (no `model ...` line found)."

    # ---- build markdown ----
    L = []
    A = L.append
    A("# %s — build cost & token report" % REPO.split("/")[-1])
    A("")
    A(f"> Generated by `report/gen_report.py` from ArchUnitDev harness logs ({s3_label}"
      + (f", plus local runs {', '.join('`'+label(d)+'`' for d in LOCAL_DIRS)}" if LOCAL_DIRS else "")
      + ") and GitHub issue metadata. Raw data captured at model-invocation granularity.")
    A("")
    A("## 1. Scope and methodology")
    A("")
    A(f"- **Target:** [`{REPO}`](https://github.com/{REPO}) — built issue-by-issue by the ArchUnitDev loop.")
    A(f"- **Model:** {model_line}")
    A("- **Loop mechanics per issue:** implement → deterministic gate → three read-only critics (review / tests / idiom; tests runs twice and the passes are unioned) → fix round; up to 3 fix rounds, then abandon, with one re-attempt on the batch's final tree.")
    A(f"- **Window:** {when(run_start)} → {when(run_end)} ({run_hours:.2f} h), first to last timestamp in the narration.")
    A("- **Cost granularity:** every model invocation has a `total_cost_usd` (sum of per-step `step_finish.cost`, which opencode prices from its own model table). Every step's token counts (`input`, `output`, `reasoning`, `cache.read`, `cache.write`) are recorded in the raw `.jsonl`.")
    A("- **Currency:** USD. **Model spend only** in the headline; AWS infrastructure is itemised in §6 and the bill cross-checked in §8.")
    A("")
    A("## 2. Grand totals")
    A("")
    A("| Metric | Value |")
    A("|---|---:|")
    A(f"| Issues landed | {landed_n} of {len(issues_sorted)} |")
    for k in ("held back", "abandoned", "in progress", "not attempted", "closed (not by this run)"):
        if counts[k]:
            A(f"| Issues {k} | {counts[k]} |")
    A(f"| Total model spend (all invocations) | **${f4(grand['cost'])}** |")
    if LOCAL_DIRS:
        A(f"|  — local (bring-up runs) | ${f4(grand['local'])} |")
        A(f"|  — EC2 (all attempts) | ${f4(grand['ec2'])} |")
    A(f"| Model invocations | {grand['inv']:,} |")
    A(f"| Implement invocations (fresh attempts incl. retries) | {grand['impl']:,} |")
    A(f"| Total model turns (assistant steps) | {grand['turns']:,}{' \\*' if rows_lost else ''} |")
    A(f"| Tokens — input | {fmt(grand['tokens']['input'])} |")
    A(f"| Tokens — output | {fmt(grand['tokens']['output'])} |")
    A(f"| Tokens — reasoning | {fmt(grand['tokens']['reasoning'])} |")
    A(f"| Tokens — cache read | {fmt(grand['tokens']['cache_read'])} |")
    A(f"| Tokens — cache write | {fmt(grand['tokens']['cache_write'])} |")
    A(f"| Total findings raised by critics | {grand['findings']:,} |")
    A(f"| Critic verdicts — PASS / FAIL | {grand['verdicts']['PASS']} / {grand['verdicts']['FAIL']} |")
    A("")
    A(f"- Effective cost per landed issue: **${f4(grand['cost'] / max(1, landed_n))}**"
      + (" (spend on issues still in progress or abandoned is included, so this falls as they land)" if counts["in progress"] or counts["abandoned"] else ""))
    A(f"- Effective cost per model turn: **${f6(grand['cost']/max(1,grand['turns']))}**")
    A("")
    A("> Note on cache-read tokens: `cache.read` is the model re-reading the running conversation context on every step — billed at the provider's cache-discount rate, which is why it contributes so little to cost per token. Input/output/reasoning are the \"new\" tokens; `cache.write` is context written to the cache, billed at a premium over input.")
    A("")
    if rows_lost:
        A(f"\\* **Turns and tokens undercount by {rows_lost} invocation(s)** whose `.json` files were overwritten by a later attempt (turn counts are not in the `run.log` ledger). Cost is not affected — it is recovered from the ledger.")
        A("")
    A("## 3. Per-issue table")
    A("")
    A("| # | Issue | Status | $ cost | invocations | attempts¹ | rounds² | turns | input | output | reasoning | cache.read | cache.write | findings | PASS/FAIL |")
    A("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for n in issues_sorted:
        title = gh[n][0]
        if n not in per_issue:
            A(f"| {n} | {title} | {status(n)} | — | — | — | — | — | — | — | — | — | — | — | — |")
            continue
        pi = per_issue[n]; t = pi["tokens"]
        A(f"| {n} | {title} | {status(n)} | ${f4(pi['cost'])} | {pi['inv']} | {pi['impl']} | {pi['rounds_max']} | {pi['turns']} | {fmt(t['input'])} | {fmt(t['output'])} | {fmt(t['reasoning'])} | {fmt(t['cache_read'])} | {fmt(t['cache_write'])} | {pi['findings']} | {pi['verdicts']['PASS']}/{pi['verdicts']['FAIL']} |")
    A("")
    A("¹ attempts = number of `implement` invocations (a fresh implementation, including re-attempts after abandonment). ² rounds = highest review round reached (1 = passed on the first review of the implementation).")
    A("")
    if overwritten:
        A("> **Cost vs token/round columns for re-attempted issues.** For issues whose earlier attempts were overwritten, the `$ cost` column is the **authoritative total across every attempt** (recovered from the `run.log` ledger — see §9). Their `invocations`, `attempts`, `rounds`, `turns` and token columns cover **only the surviving files**. For all other issues the two are identical.")
        A("")
    A("## 4. Abandoned and re-attempted issues")
    A("")
    if abandoned:
        A("Issues abandoned at least once (no unanimous critic PASS within the round budget), counted from the `ABANDONED` lines in the narration. Cost shown is the **total across all attempts**.")
        A("")
        A("| # | Issue | Abandonments | Outcome | Total cost |")
        A("|---|---|:---:|---|---:|")
        for n in sorted(abandoned):
            cost = f"${f4(per_issue[n]['cost'])}" if n in per_issue else "—"
            A(f"| {n} | {gh.get(n, ('',))[0]} | {abandoned[n]} | {status(n)} | {cost} |")
    else:
        A("None: every attempted issue got a unanimous PASS within its round budget on the first attempt.")
    A("")
    A("## 5. Per-invocation detail")
    A("")
    A("Every model invocation, in queue order (implement → fix → review → tests → idiom), keyed by `issue-role[-round][a/b]`. `retry` invocations are the re-attempt pass. Source `local` = bring-up runs; `ec2` = the EC2 host (synced to S3).")
    A("")
    if rows_lost:
        A(f"> **Completeness:** {len(invocations)} invocation rows are listed; the true count (all attempts, from the ledger) is {grand['inv']}. The {rows_lost} missing rows were overwritten by a later attempt; their costs are in the totals via the `run.log` ledger, their per-step tokens are unrecoverable.")
        A("")
    A("| tag | run | role | round | retry | source | $ cost | turns | reason | verdict | findings | in | out | reas. | cache.r | cache.w |")
    A("|---|---|---|---|---|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|")
    for x in invocations:
        t = x["tokens"]
        A(f"| {x['tag']} | {x['run']} | {x['role']} | {x['round'] or ''}{x['suffix'] or ''} | {'yes' if x['retry'] else ''} | {x['source']} | ${f4(x['cost'])} | {x['turns']} | {x['reason']} | {x['verdict'] or ''} | {x['findings']} | {fmt(t['input'])} | {fmt(t['output'])} | {fmt(t['reasoning'])} | {fmt(t['cache_read'])} | {fmt(t['cache_write'])} |")
    A("")

    # ---- infrastructure ----
    infra_total = None
    A("## 6. AWS infrastructure cost (non-model spend)")
    A("")
    if a.infra:
        spec = json.load(open(a.infra, encoding="utf-8"))
        hours = spec.get("hours") or run_hours
        A(f"The ${f2(grand['cost'])} above is **model spend only**. {spec.get('note', '')}")
        A("")
        A("| Resource | Detail | Quantity | Rate | Hours | Cost |")
        A("|---|---|---:|---:|---:|---:|")
        infra_total = 0.0
        for r in spec["rows"]:
            per_hour = r["rate"] if r["unit"] == "hr" else r["rate"] / 730  # GB-Mo: AWS bills a month as 730 h
            cost = r["count"] * per_hour * hours
            infra_total += cost
            unit = "GB" if r["unit"] == "GB-Mo" else ""
            A(f"| {r['resource']} | {r['detail']} | {r['count']}{' ' + unit if unit else ''} | ${r['rate']}/{r['unit']} | {hours:.2f} | ${f2(cost)} |")
        A(f"| **Subtotal** | | | | | **${f2(infra_total)}** |")
    else:
        A("Not itemised: pass `--infra` with a `report/infra-*.json` file describing the run's hosts.")
    A("")
    A("## 7. Combined total")
    A("")
    A("| Component | Cost |")
    A("|---|---:|")
    A(f"| Model spend (this report's headline) | ${f2(grand['cost'])} |")
    if infra_total is not None:
        A(f"| AWS infrastructure (§6) | ${f2(infra_total)} |")
        A(f"| **Combined** | **${f2(grand['cost'] + infra_total)}** |")
        A("")
        A("> The infrastructure line is an estimate from published on-demand rates. Human oversight time is excluded.")
    A("")

    # ---- cross-checks ----
    A("## 8. Cross-checks against AWS")
    A("")
    did = False
    if a.cloudwatch_model and run_start:
        cw = cloudwatch_tokens(a.cloudwatch_model, a.aws_region, run_start, run_end + timedelta(minutes=10))
        if cw:
            did = True
            steps = sum(x["turns"] for x in invocations if x["source"] == "ec2")
            g = defaultdict(int)
            for x in invocations:
                if x["source"] == "ec2":
                    for k, v in x["tokens"].items(): g[k] += v
            A(f"Bedrock's CloudWatch metrics for `{a.cloudwatch_model}` in {a.aws_region} over the run window (+10 min), against the EC2 logs. One model request is one opencode step, so `Invocations` compares with turns.")
            A("")
            A("| | CloudWatch | Harness logs | Δ |")
            A("|---|---:|---:|---:|")
            for name, cwk, hv in (("Requests / steps", "Invocations", steps),
                                  ("Input", "InputTokenCount", g["input"]),
                                  ("Output", "OutputTokenCount", g["output"]),
                                  ("Cache read", "CacheReadInputTokenCount", g["cache_read"]),
                                  ("Cache write", "CacheWriteInputTokenCount", g["cache_write"])):
                c = cw[cwk]
                d = f"{(hv - c) / c * 100:+.1f}%" if c else "—"
                A(f"| {name} | {fmt(c)} | {fmt(hv)} | {d} |")
            A("")
            A("> CloudWatch counts every request to that model ID in the account, so any call made outside the loop in the window is included; the harness counts only what the loop logged. A run still in progress also differs by whatever invocation is in flight.")
            A("")
    if a.cost_explorer and run_start:
        ce = cost_explorer(run_start, run_end)
        if ce and not any(v >= 0.005 for v in ce[2].values()):
            did = True
            A(f"Cost Explorer has no cost yet for {ce[0]} to {ce[1]} (it lags usage by up to a day); regenerate later for the by-service bill.")
            A("")
        elif ce:
            did = True
            s, e, by = ce
            A(f"Cost Explorer, unblended, **account-wide**, whole UTC days {s} to {e} (exclusive) — it includes anything else the account ran on those days and lags usage by up to a day, so it is a ceiling to check the estimates above against, not a replacement for them.")
            A("")
            A("| Service | Cost |")
            A("|---|---:|")
            for svc, v in sorted(by.items(), key=lambda kv: -kv[1]):
                if v >= 0.005:
                    A(f"| {svc} | ${f2(v)} |")
            A(f"| **Total** | **${f2(sum(by.values()))}** |")
            A("")
    if not did:
        A("Not run: pass `--cloudwatch-model <bedrock model id>` and/or `--cost-explorer` (Bedrock runs only; needs AWS credentials for the account).")
        A("")

    # ---- caveats, computed from the data rather than asserted ----
    A("## 9. Caveats & data notes")
    A("")
    if overwritten:
        lost = sum(v for _, v in overwritten)
        A(f"- **Re-attempted issues overwrote their log files** ({', '.join('#%d' % n for n, _ in sorted(overwritten))}): an attempt in a later run reuses the earlier attempt's tag names. Their **cost (${f4(lost)}) is recovered from the `run.log` ledger**, but their per-step **token data is lost**, so those issues' token rows cover only the surviving attempt.")
    else:
        A("- **No attempt's files were overwritten:** the surviving `.json` files account for the whole `run.log` ledger, so the token and turn columns cover every invocation.")
    A("- **`total_cost_usd` = sum of step `cost`s**, priced by opencode from its model table (cache discounts included) — not read from a bill. §8 is the check against the bill.")
    if grand["tokens"]["cache_write"] == 0:
        A("- **`cache.write` is 0 across the build** — the provider reported no cache writes, only cache reads.")
    else:
        A(f"- **Cache writes are reported** ({fmt(grand['tokens']['cache_write'])} tokens): the provider bills writing context into the cache at a premium over plain input, so on a model with prompt caching they are a large share of cost despite a modest token count.")
    if grand["tokens"]["reasoning"] == 0 and grand["tokens"]["output"] > 0:
        A("- **Reasoning tokens are 0 throughout.** Either extended thinking was not enabled at this variant, or the provider folds thinking into `output` rather than reporting it separately. Compare the `output` column, not `reasoning`, against a model that reports reasoning on its own.")
    if failed_closed:
        A(f"- {failed_closed} critic invocation(s) returned `no verdict in the output — failing closed` (FAIL with a synthesised finding). They are real failures (a crashed or timed-out invocation), not free work.")
    if counts["in progress"] or counts["not attempted"]:
        A(f"- **The run was still in progress** when this was generated ({counts['in progress'] + counts['not attempted']} issue(s) not yet landed); regenerate once it finishes.")
    A("- Gate runs (deterministic, no model) cost nothing and are not listed.")
    A("")
    A("## 10. Machine-readable source")
    A("")
    A("This report is derived from:")
    if LOCAL_DIRS:
        A(f"- Local bring-up logs: {', '.join('`'+label(d)+'`' for d in LOCAL_DIRS)}")
    A(f"- EC2 logs: {s3_label}")
    A("- The per-invocation CSV (issue, tag, role, round, retry, source, cost, turns, reason, verdict, findings, in/out/reasoning/cache tokens) is regenerable from the same data.")
    A("")
    A("---")
    A("")
    A("*Report generated by `report/gen_report.py`. Model spend is the source of truth for cross-model comparison (a fresh model run should reuse the identical loop + log layout).*")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", OUT, len(L), "lines")


def fetch_issue_metadata(repo):
    """Issue number -> (title, state, closedAt). Prefers live `gh`; the bundled snapshot is the
    ArchUnitSharp backlog as the deepseek-v4-flash build left it, and is used for no other repo."""
    SNAP = [
        (1,"Kernel: Edge, Graph and ImportKind","CLOSED","2026-08-25T20:54:32Z"),
        (2,"Kernel: pattern matching — globs, regex and match targets","CLOSED","2026-08-26T08:33:33Z"),
        (3,"Kernel: RegexFactory and the matcher factories","CLOSED","2026-08-26T09:53:03Z"),
        (4,"Kernel: Violation base type and EmptyTestViolation","CLOSED","2026-08-26T09:53:04Z"),
        (5,"Kernel: CheckOptions and the Checkable contract","CLOSED","2026-08-26T13:15:31Z"),
        (6,"Kernel: TechnicalError and UserError","CLOSED","2026-08-26T13:15:32Z"),
        (7,"Extraction: locate the project and enumerate source files","CLOSED","2026-08-26T14:45:34Z"),
        (8,"Extraction: parse imports and resolve them to targets","CLOSED","2026-08-27T16:01:33Z"),
        (9,"Extraction: classify internal vs external dependencies","CLOSED","2026-08-27T16:01:34Z"),
        (10,"Extraction: self-edges and parallel-edge merging","CLOSED","2026-08-27T18:57:41Z"),
        (11,"Extraction: graph cache and clear-graph-cache","CLOSED","2026-08-27T18:57:42Z"),
        (12,"Extraction: per-line ignore directive","CLOSED","2026-08-27T18:57:42Z"),
        (13,"Projection: project edges, nodes and cycles","CLOSED","2026-08-27T18:57:43Z"),
        (14,"Projection: the per-edge MapFunctions","CLOSED","2026-08-27T18:57:43Z"),
        (15,"Projection: cycle detection — Tarjan and Johnson","CLOSED","2026-08-27T19:10:26Z"),
        (16,"Files API: entry point and selectors","CLOSED","2026-08-27T19:29:35Z"),
        (17,"Files API: should and should not","CLOSED","2026-08-27T19:53:28Z"),
        (18,"Files API: have no cycles","CLOSED","2026-08-27T20:18:08Z"),
        (19,"Files API: have name, be in folder, be in path","CLOSED","2026-08-27T20:33:40Z"),
        (20,"Files API: depend on files","CLOSED","2026-08-27T21:55:26Z"),
        (21,"Files API: depend on external modules","CLOSED","2026-08-27T22:10:54Z"),
        (22,"Files API: adhere to — custom user predicate","CLOSED","2026-08-27T22:28:53Z"),
        (23,"The empty-test guard on every terminal","CLOSED","2026-08-27T22:44:23Z"),
        (24,"Testing: violation formatting, result shaping and colour","CLOSED","2026-08-27T22:57:21Z"),
        (25,"Testing: the framework-agnostic assert helper","CLOSED","2026-08-27T23:08:52Z"),
        (26,"Testing: native integration with xUnit, with NUnit and MSTest covered by the agnostic path","CLOSED","2026-08-27T23:39:05Z"),
        (27,"Layers API","CLOSED","2026-08-30T17:38:21Z"),
        (28,"Graph reports: the snapshot and its query options","CLOSED","2026-08-30T20:56:44Z"),
        (29,"Graph reports: the six output formats","CLOSED","2026-08-30T20:02:23Z"),
        (30,"Slices API: slicing projections and forbidden dependencies","CLOSED","2026-08-31T12:42:42Z"),
        (31,"Slices API: PlantUML component diagrams","CLOSED","2026-08-31T13:55:38Z"),
        (32,"Metrics: extraction and count metrics","CLOSED","2026-08-31T15:48:31Z"),
        (33,"Metrics: the LCOM family","CLOSED","2026-08-31T16:46:31Z"),
        (34,"Metrics: distance metrics and the zone checks","CLOSED","2026-08-31T17:56:58Z"),
        (35,"Metrics: custom metrics","CLOSED","2026-08-31T18:54:53Z"),
        (36,"Metrics: threshold verbs","CLOSED","2026-09-01T21:12:55Z"),
        (37,"Metrics: HTML report export","CLOSED","2026-09-01T21:12:56Z"),
        (38,"Pattern exclusions — the `except` companion","CLOSED","2026-09-01T21:12:56Z"),
        (39,"Logging","CLOSED","2026-09-01T21:12:57Z"),
        (40,"Dogfood: enforce our own architecture rules on ourselves","CLOSED","2026-09-01T21:13:01Z"),
        (41,"README someone can actually start from","CLOSED","2026-09-01T21:12:58Z"),
        (42,"Documentation site on GitHub Pages","CLOSED","2026-09-01T21:12:59Z"),
        (43,"CI: build, test and lint on every push","CLOSED","2026-09-01T21:12:59Z"),
        (44,"Publish to NuGet","OPEN",None),
        (45,"Restore the full test suite to green across the CI matrix","CLOSED","2026-09-01T21:13:00Z"),
        (46,"Prevent Metrics<T>() from silently passing without analyzing the target type","CLOSED","2026-09-01T21:13:01Z"),
    ]
    try:
        r = subprocess.run(
            ["gh", "issue", "list", "-R", repo, "--state", "all", "--limit", "500",
             "--json", "number,state,title,closedAt"],
            capture_output=True, text=True, timeout=30, check=True)
        rows = json.loads(r.stdout)
        if rows:
            return {int(x["number"]): (x["title"], x["state"], x.get("closedAt")) for x in rows}
    except Exception as e:
        print(f"gh unavailable ({e})", file=sys.stderr)
    if repo != "RobeyBeswick/ArchUnitSharp":
        sys.exit(f"cannot read issues for {repo} and the bundled snapshot is ArchUnitSharp's; authenticate gh")
    print("using the bundled ArchUnitSharp issue snapshot", file=sys.stderr)
    return {n: (t, s, c) for n, t, s, c in SNAP}


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate a granular cost/token build report from ArchUnitDev harness logs.

Aggregates per-issue and per-invocation cost + token data from the loop's
`logs/` directory (the same layout run.sh writes locally and log-sync.sh ships
to S3). Merges two sources:

  * local bring-up runs (default: this repo's `logs/csharp*` + `logs/container-run`)
  * an EC2 log dir synced from S3 (default: `./s3logs`)

Costs for re-attempted issues are reconciled against the authoritative
`run.log` ledger, because a later attempt overwrites the earlier attempt's
tag-named `*.json`/`*.jsonl` files on S3 (see Caveats in the generated report).

Usage:
    # stage an EC2 log prefix locally, then run:
    aws s3 sync s3://<bucket>/loop/<RUN_ID> ./s3logs
    python3 report/gen_report.py \
        --local-logs logs/csharp1,logs/csharp1b,... \
        --s3-logs ./s3logs \
        --out ArchUnitSharp-build-report.md \
        --repo RobeyBeswick/ArchUnitSharp

Environment overrides:
    LOCAL_LOGS   comma-separated dirs (fallback: logs/csharp*, logs/container-run)
    S3_LOGS      EC2 log dir
    OUT          output markdown path
    TARGET_REPO  GitHub repo for issue/commit metadata

Requires: python3 + jq (used to fetch issue metadata if `gh` is available).
"""
import json, os, re, sys, glob, subprocess, tempfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

def env_list(name, default):
    return [d for d in (os.environ.get(name) or default).split(",") if d]

def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--local-logs", help="comma-separated local log dirs")
    ap.add_argument("--s3-logs", help="EC2/S3 log dir (run.log + *.json/jsonl)")
    ap.add_argument("--out", help="output markdown path")
    ap.add_argument("--repo", default="RobeyBeswick/ArchUnitSharp", help="GitHub repo")
    a = ap.parse_args()

    LOCAL_DIRS = a.local_logs.split(",") if a.local_logs else env_list(
        "LOCAL_LOGS", ",".join(sorted(glob.glob(os.path.join(REPO_ROOT, "logs/csharp*")) +
                                      glob.glob(os.path.join(REPO_ROOT, "logs/container-run")))))
    S3_DIR = a.s3_logs or os.environ.get("S3_LOGS") or os.path.join(REPO_ROOT, "s3logs")
    OUT = a.out or os.environ.get("OUT") or os.path.join(REPO_ROOT, "ArchUnitSharp-build-report.md")
    REPO = a.repo or os.environ.get("TARGET_REPO") or "RobeyBeswick/ArchUnitSharp"

    LOCAL_DIRS = [d for d in LOCAL_DIRS if os.path.isdir(d)]
    if not LOCAL_DIRS:
        sys.exit("no local log dirs found; pass --local-logs")
    if not os.path.isdir(S3_DIR):
        sys.exit(f"S3 log dir not found: {S3_DIR}; pass --s3-logs (e.g. an `aws s3 sync` of a /loop/<RUN_ID> prefix)")

    gh = fetch_issue_metadata(REPO)
    commits = fetch_commits(REPO)

    # landed commit per issue (title match against commit messages)
    def norm(s):
        return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
    landed = {}
    for sha, date, msg in commits:
        nm = norm(msg)
        for n, (t, s, c) in gh.items():
            if s == "CLOSED" and norm(t) == nm:
                landed[n] = sha

    # base commits per issue (from run logs)
    base_commits = {}
    base_re = re.compile(r"issue #(\d+): .*?\(base ([0-9a-f]{7})")
    for d in LOCAL_DIRS + [S3_DIR]:
        for lp in glob.glob(os.path.join(d, "loop.out")) + glob.glob(os.path.join(d, "run.log")):
            try:
                for line in open(lp, encoding="utf-8", errors="replace"):
                    for m in base_re.finditer(line):
                        base_commits[int(m.group(1))] = m.group(2)
            except Exception:
                pass

    # authoritative EC2 cost ledger from run.log (all attempts, incl. overwritten re-attempts)
    LEDGER = re.compile(r"^\S+\s+(\d+)-([a-z0-9-]+): .*cost=\$([0-9.]+)")
    ledger = defaultdict(float)
    for lp in glob.glob(os.path.join(S3_DIR, "run.log")):
        for line in open(lp, encoding="utf-8", errors="replace"):
            m = LEDGER.match(line.strip())
            if m:
                ledger[int(m.group(1))] += float(m.group(3))
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
    for d in LOCAL_DIRS + [S3_DIR]:
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
            run = os.path.basename(d.rstrip("/"))
            invocations.append({
                "tag": tag, "run": run, "issue": issue, "role": role, "round": rnd, "suffix": suffix,
                "retry": retry, "source": source, "cost": j.get("total_cost_usd") or 0,
                "turns": j.get("num_turns") or 0, "reason": j.get("terminal_reason") or "",
                "verdict": verdict, "findings": findings, "tokens": toks,
            })

    ROLE_ORDER = {"implement":0, "fix":1, "review":2, "tests":3, "idiom":4}
    invocations.sort(key=lambda x: (x["issue"], ROLE_ORDER.get(x["role"], 9),
        int(x["round"]) if x["round"] else 0, x["suffix"] or "", x["retry"]))

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
    for n in list(per_issue.keys()):
        if n in ledger and ledger[n] > per_issue[n]["ec2"] + 1e-9:
            per_issue[n]["ec2"] = ledger[n]
            per_issue[n]["cost"] = per_issue[n]["local"] + ledger[n]
            print(f"issue {n}: ec2 cost corrected -> {ledger[n]:.4f} (overwritten attempts recovered from run.log)", file=sys.stderr)

    grand = {"cost":0.0, "turns":0, "inv":0, "impl":0, "tokens":defaultdict(int),
             "verdicts":defaultdict(int), "findings":0, "local":0.0, "ec2":0.0}
    for n, pi in per_issue.items():
        for k in grand:
            if isinstance(grand[k], defaultdict) or isinstance(grand[k], dict):
                for kk in pi[k]: grand[k][kk] += pi[k][kk]
            else:
                grand[k] += pi[k]

    # True invocation/implement counts: local = surviving json (complete); EC2 = ledger (all attempts).
    ledger_inv = 0
    ledger_impl = 0
    for lp in glob.glob(os.path.join(S3_DIR, "run.log")):
        for line in open(lp, encoding="utf-8", errors="replace"):
            if re.search(r": .*cost=\$", line):
                ledger_inv += 1
                if re.search(r": rc=\d+ cost=", line) and re.search(r"\d+-(?:retry-)?implement:", line):
                    ledger_impl += 1
    local_inv = sum(1 for x in invocations if x["source"] == "local")
    local_impl = sum(1 for x in invocations if x["source"] == "local" and x["role"] == "implement")
    grand["inv"] = local_inv + ledger_inv
    grand["impl"] = local_impl + ledger_impl

    def f2(v): return f"{v:.2f}"
    def f4(v): return f"{v:.4f}"
    def f6(v): return f"{v:.6f}"
    def fmt(v): return f"{v:,}"

    issues_sorted = sorted(gh.keys())

    # ---- build markdown ----
    L = []
    A = L.append
    A("# %s — full build cost & token report" % REPO.split("/")[-1])
    A("")
    A(f"> Generated from ArchUnitDev harness logs (local `logs/` + S3 `{S3_DIR}`) and GitHub issue/commit metadata. Raw data captured at model-invocation granularity.")
    A("")
    A("## 1. Scope and methodology")
    A("")
    A(f"- **Target:** [`{REPO}`](https://github.com/{REPO}) — built issue-by-issue by the ArchUnitDev loop.")
    A("- **Model:** `opencode-go/deepseek-v4-flash` for implement, all three critics, fix and retro; `VARIANT=high`. (No model split — one model for everything.)")
    A("- **Loop mechanics per issue:** implement → deterministic gate → up to 3 parallel critics (review / tests / idiom) → fix round; up to 3 fix rounds, then abandon-and-retry on a later batch.")
    A("- **Date range:** earliest issue start → latest issue close (see per-issue table).")
    A("- **Cost granularity:** every model invocation has a `total_cost_usd` (sum of per-step `step_finish.cost`). Every step's token counts (`input`, `output`, `reasoning`, `cache.read`, `cache.write`) are recorded in the raw `.jsonl`.")
    A("- **Currency:** USD. **Model spend only** in the headline; AWS infrastructure cost is itemised in §6.")
    A("")
    A("## 2. Grand totals")
    A("")
    A("| Metric | Value |")
    A("|---|---:|")
    A(f"| Issues landed (closed on GitHub) | {sum(1 for n in issues_sorted if gh[n][1]=='CLOSED')} of {len(issues_sorted)} |")
    A(f"| Issues skipped by hand | {sum(1 for n in issues_sorted if gh[n][1]!='CLOSED')} |")
    A(f"| Total model spend (all invocations) | **${f4(grand['cost'])}** |")
    A(f"|  — local (bring-up runs) | ${f4(grand['local'])} |")
    A(f"|  — EC2 (all attempts incl. overwritten re-attempts) | ${f4(grand['ec2'])} |")
    A(f"| Model invocations | {grand['inv']:,} |")
    A(f"| Implement invocations (fresh attempts incl. retries) | {grand['impl']:,} |")
    A(f"| Total model turns (assistant steps) | {grand['turns']:,} \\* |")
    A(f"| Tokens — input | {fmt(grand['tokens']['input'])} |")
    A(f"| Tokens — output | {fmt(grand['tokens']['output'])} |")
    A(f"| Tokens — reasoning | {fmt(grand['tokens']['reasoning'])} |")
    A(f"| Tokens — cache read | {fmt(grand['tokens']['cache_read'])} |")
    A(f"| Tokens — cache write | {fmt(grand['tokens']['cache_write'])} |")
    A(f"| Total findings raised by critics | {grand['findings']:,} |")
    A(f"| Critic verdicts — PASS / FAIL | {grand['verdicts']['PASS']} / {grand['verdicts']['FAIL']} |")
    A("")
    cost_per = grand["cost"] / max(1, sum(1 for n in issues_sorted if gh[n][1]=='CLOSED'))
    A(f"- Effective cost per landed issue: **${f4(cost_per)}**")
    A(f"- Effective cost per model turn: **${f6(grand['cost']/max(1,grand['turns']))}**")
    A("")
    A("> Note on cache-read tokens: `cache.read` is the model re-reading the running conversation context on every step — billed at the provider's cache-discount rate, which is why it contributes so little to cost. Input/output/reasoning are the \"new\" tokens.")
    A("")
    A("\\* **Turns undercounts by the lost re-attempt invocations** (their `.json` files were overwritten; turn counts are not in the `run.log` ledger). Cost is not affected — it is recovered from the ledger. Tokens likewise cover only surviving files.")
    A("")
    A("## 3. Per-issue table")
    A("")
    A("| # | Issue | Status | $ cost | invocations | attempts¹ | rounds² | turns | input | output | reasoning | cache.read | findings | PASS/FAIL |")
    A("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for n in issues_sorted:
        title, state, closed = gh[n]
        if n not in per_issue:
            A(f"| {n} | {title} | {state} | — | — | — | — | — | — | — | — | — | — | — |")
            continue
        pi = per_issue[n]
        status = "landed" if state == "CLOSED" else "skipped"
        A(f"| {n} | {title} | {status} | ${f4(pi['cost'])} | {pi['inv']} | {pi['impl']} | {pi['rounds_max']} | {pi['turns']} | {fmt(pi['tokens']['input'])} | {fmt(pi['tokens']['output'])} | {fmt(pi['tokens']['reasoning'])} | {fmt(pi['tokens']['cache_read'])} | {pi['findings']} | {pi['verdicts']['PASS']}/{pi['verdicts']['FAIL']} |")
    A("")
    A("¹ attempts = number of `implement` invocations (a fresh implementation, including re-attempts after abandonment). ² rounds = highest fix round reached (1 = landed after the first implementation review cycle).")
    A("")
    A("> **Cost vs token/round columns for re-attempted issues.** For issues whose earlier attempts were overwritten, the `$ cost` column is the **authoritative total across every attempt** (recovered from the `run.log` ledger — see §8). Their `invocations`, `attempts`, `rounds`, `turns` and token columns cover **only the surviving files** (the final attempt). For all other issues the two are identical.")
    A("")
    A("## 4. Re-attempted / abandoned issues")
    A("")
    A("Issues abandoned at least once (failed to reach a unanimous critic PASS within the round budget) and later re-attempted. Cost shown is the **total across all attempts**.")
    A("")
    A("| # | Issue | Abandonments | Total cost |")
    A("|---|---|:---:|---:|")
    abandonments = {
        1: ("abandoned locally; later re-landed", 1),
        7: ("abandoned locally twice; later re-landed", 2),
        27: ("abandoned 3× (EC2); later re-landed", 3),
        28: ("abandoned; re-attempt landed same day", 1),
        40: ("abandoned; re-attempt landed same day", 1),
    }
    for n in sorted(abandonments):
        note, cnt = abandonments[n]
        if n in per_issue:
            A(f"| {n} | {gh.get(n,('',))[0]} | {cnt} | ${f4(per_issue[n]['cost'])} |")
    A("")
    A("## 5. Per-invocation detail")
    A("")
    A("Every model invocation across the whole build, in queue order (implement → fix → review → tests → idiom), keyed by `issue-role[-round][a/b]`. `retry` invocations are the re-attempt pass. Source `local` = bring-up runs; `ec2` = the EC2 host (synced to S3).")
    A("")
    A(f"> **Completeness:** this table lists only invocations whose files survive (the final attempt of each re-attempted issue). Some earlier-attempt files are gone (overwritten on S3); their costs are included in the totals via the `run.log` ledger but their per-step tokens are unrecoverable. In total {len(invocations)} invocation rows are listed; the true invocation count (all attempts) is {grand['inv']}.")
    A("")
    A("| tag | run | role | round | retry | source | $ cost | turns | reason | verdict | findings | in | out | reas. | cache.r | cache.w |")
    A("|---|---|---|---|---|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|")
    for x in invocations:
        t = x["tokens"]
        A(f"| {x['tag']} | {x['run']} | {x['role']} | {x['round'] or ''}{x['suffix'] or ''} | {'yes' if x['retry'] else ''} | {x['source']} | ${f4(x['cost'])} | {x['turns']} | {x['reason']} | {x['verdict'] or ''} | {x['findings']} | {fmt(t['input'])} | {fmt(t['output'])} | {fmt(t['reasoning'])} | {fmt(t['cache_read'])} | {fmt(t['cache_write'])} |")
    A("")
    A("## 6. AWS infrastructure cost (non-model spend)")
    A("")
    A(f"The ${f2(grand['cost'])} above is **model API spend only**. Running the loop also used AWS infrastructure for the EC2-hosted batches. Reconstructed from `terraform.tfstate`, EC2/EBS describe calls and AWS published on-demand pricing (eu-central-1 / Frankfurt), 2026 rates:")
    A("")
    A("| Resource | Detail | Rate | Hours | Cost |")
    A("|---|---|---:|---:|---:|")
    A("| EC2 instance | t3.large (2 vCPU / 8 GiB), AL2023 | $0.096/hr | 127.62 | $12.25 |")
    A("| EBS root volume | 30 GB gp3, encrypted | $0.08/GB-mo | 127.62 | $0.42 |")
    A("| NAT gateway | 1 × | $0.052/hr | 127.62 | $6.64 |")
    A("| Secrets Manager interface endpoint | 1 AZ | $0.012/hr | 127.62 | $1.53 |")
    A("| Elastic IP (in-use) | | $0.005/hr | 127.62 | $0.64 |")
    A("| **Subtotal (compute + network)** | | | | **$21.48** |")
    A("")
    A("- Instance window: launched 2026-08-27T13:44:04Z, stopped 2026-09-01T21:21:14Z (user-initiated) = **127.62 h / 5.32 d**.")
    A("- NAT/endpoint/EIP were provisioned for the whole window; exact data volumes are not itemised here.")
    A("- ECR image registry, S3 bucket and Secrets Manager secrets are effectively free at this scale and not itemised.")
    A("")
    A("## 7. Combined total")
    A("")
    A("| Component | Cost |")
    A("|---|---:|")
    A(f"| Model spend (this report's headline) | ${f2(grand['cost'])} |")
    A("| AWS infrastructure (compute + network, §6) | $21.48 |")
    A(f"| **Combined** | **${f2(grand['cost'] + 21.48)}** |")
    A("")
    A("> The $21.48 infra line is an estimate from published on-demand rates. Human oversight time is excluded.")
    A("")
    A("## 8. Caveats & data notes")
    A("")
    A("- The EC2 cost is taken from the authoritative `run.log` ledger (all attempts); a naive sum of surviving `*.json` undercounts because re-attempted issues overwrite their earlier-attempt files.")
    A("- **Re-attempted issues overwrite their log files.** Earlier attempts' `*.json`/`*.jsonl` are overwritten on S3 by the final attempt. Their **cost is recovered from the `run.log` ledger**, but their per-step **token data is lost** (files gone) — the affected issue's token row covers only its final attempt, while its cost covers all attempts.")
    A("- **`total_cost_usd` = sum of step `cost`s** the provider reported (cache discounts included). `total` tokens in a step = input + output + cache.read (the running-context re-read).")
    A("- **`cache.write` is 0 across the build** — the provider reported no cache writes, only cache reads.")
    A("- A few invocations returned `no verdict in the output — failing closed` (`$0` cost, FAIL, 1 finding \"no verdict returned\"). They are real failures (a crashed/timeout invocation), not free work.")
    A("- Gate runs (deterministic, no model) cost nothing and are not listed.")
    A("")
    A("## 9. Machine-readable source")
    A("")
    A("This report is derived from:")
    A(f"- Local bring-up logs: `{', '.join(LOCAL_DIRS)}`")
    A(f"- EC2 logs: `{S3_DIR}` (synced from S3 `/loop/<RUN_ID>` prefix)")
    A("- The per-invocation CSV (issue, tag, role, round, retry, source, cost, turns, reason, verdict, findings, in/out/reasoning/cache tokens) is regenerable from the same data.")
    A("")
    A("---")
    A("")
    A("*Report generated by `report/gen_report.py`. Model spend is the source of truth for cross-model comparison (a fresh model run should reuse the identical loop + log layout).*")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", OUT, len(L), "lines")


def fetch_issue_metadata(repo):
    """Issue number -> (title, state, closedAt). Prefers live `gh`, falls back to a bundled snapshot."""
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
            ["gh", "issue", "list", "-R", repo, "--state", "all", "--limit", "200",
             "--json", "number,state,title,closedAt"],
            capture_output=True, text=True, timeout=30, check=True)
        rows = json.loads(r.stdout)
        if rows:
            return {int(x["number"]): (x["title"], x["state"], x.get("closedAt")) for x in rows}
    except Exception as e:
        print(f"gh unavailable ({e}); using bundled issue snapshot", file=sys.stderr)
    return {n: (t, s, c) for n, t, s, c in SNAP}


def fetch_commits(repo):
    """List of (sha7, author_date, subject) for the default branch. Prefers live `gh`, else empty."""
    try:
        r = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits", "--paginate", "--jq",
             '.[] | "\(.sha[0:7])\\t\(.commit.author.date)\\t\(.commit.message | split("\\n")[0])"'],
            capture_output=True, text=True, timeout=60, check=True)
        out = []
        for line in r.stdout.splitlines():
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                out.append((parts[0], parts[1], parts[2]))
        return out
    except Exception as e:
        print(f"gh commit fetch unavailable ({e}); skipping landed-commit mapping", file=sys.stderr)
        return []


if __name__ == "__main__":
    main()
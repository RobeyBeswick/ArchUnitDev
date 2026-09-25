#!/usr/bin/env python3
"""Side-by-side tables for two build reports of the same backlog.

Reads the §2 grand-totals table and the §3 per-issue table of two reports written by
gen_report.py (or the hand-generated first report, which has the same two tables less the
cache.write column) and prints markdown: the totals next to each other with the ratio, how many
rounds each issue took, and every issue's cost and rounds in both builds.

It compares reports, not logs, because the two builds' logs do not live in the same place: the
deepseek-v4-flash build's EC2 logs were in an account the Opus 5.5 build never used, and the report
is the one artefact both have.

Usage:
    python3 report/compare_reports.py ArchUnitSharp-build-report.md ArchUnitSharpTest-opus-5-5-report.md \
        --labels deepseek-v4-flash "Opus 5.5" > tables.md
"""
import argparse, re, sys
from collections import Counter


def tables(path):
    """Every markdown table in the file, keyed by the section heading above it."""
    out, section, rows = {}, None, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("## "):
            section = line[3:].split(".", 1)[-1].strip().lower()
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if rows is None:
                rows = [cells]
            elif not set("".join(cells)) <= set("-:"):
                rows.append(cells)
        elif rows is not None:
            out.setdefault(section, rows)
            rows = None
    if rows is not None:
        out.setdefault(section, rows)
    return out


def num(s):
    """'$19.8640' -> 19.864, '7,183 \\*' -> 7183, '264 / 109' -> None, '—' -> None."""
    s = s.replace("*", "").replace("\\", "").replace("$", "").replace(",", "").strip()
    try:
        return float(s)
    except ValueError:
        return None


def totals(t):
    rows = next(v for k, v in t.items() if k.startswith("grand totals"))
    out = {}
    for r in rows[1:]:
        key = re.sub(r"\s*\(.*\)", "", r[0]).strip().lower()
        out[key] = r[1].replace("*", "").replace("\\", "").strip()
    return out


def per_issue(t):
    rows = next(v for k, v in t.items() if k.startswith("per-issue"))
    head = [h.lower().rstrip("¹²") for h in rows[0]]
    return {int(r[0]): dict(zip(head, r)) for r in rows[1:] if r[0].isdigit()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a"); ap.add_argument("b")
    ap.add_argument("--labels", nargs=2, default=["A", "B"])
    a = ap.parse_args()
    la, lb = a.labels
    ta, tb = tables(a.a), tables(a.b)
    ga, gb = totals(ta), totals(tb)
    ia, ib = per_issue(ta), per_issue(tb)

    P = print
    P(f"### Totals\n\n| Metric | {la} | {lb} | {lb} ÷ {la} |\n|---|---:|---:|---:|")
    for key in ("issues landed", "total model spend", "model invocations", "implement invocations",
                "total model turns", "tokens — input", "tokens — output", "tokens — reasoning",
                "tokens — cache read", "tokens — cache write", "total findings raised by critics",
                "critic verdicts — pass / fail"):
        va, vb = ga.get(key, "—"), gb.get(key, "—")
        na, nb = num(va), num(vb)
        ratio = f"{nb / na:.2f}×" if na and nb else "—"
        P(f"| {key[0].upper() + key[1:]} | {va} | {vb} | {ratio} |")
    # Input alone does not compare: Bedrock's Anthropic models put almost the whole prompt in the cache
    # (the Opus 5.5 build reported 8,938 input tokens against 383M cache reads), where deepseek-v4-flash
    # reported tens of millions as plain input. Everything the model was sent is the sum of the three.
    sent = lambda g: sum(num(g.get(k, "0")) or 0 for k in ("tokens — input", "tokens — cache read", "tokens — cache write"))
    P(f"| Tokens — everything sent (input + cache read + cache write) | {sent(ga):,.0f} | {sent(gb):,.0f} | {sent(gb) / sent(ga):.2f}× |")
    ca = sum(num(r["$ cost"]) or 0 for r in ia.values()); cb = sum(num(r["$ cost"]) or 0 for r in ib.values())
    landed = lambda d: [n for n, r in d.items() if r["status"].startswith("landed")]
    P(f"| Cost per landed issue | ${ca / len(landed(ia)):.4f} | ${cb / len(landed(ib)):.4f} | {cb / ca * len(landed(ia)) / len(landed(ib)):.2f}× |")
    ta_, tb_ = num(ga["total model turns"]), num(gb["total model turns"])
    P(f"| Cost per model turn | ${ca / ta_:.6f} | ${cb / tb_:.6f} | {(cb / tb_) / (ca / ta_):.2f}× |")

    P(f"\n### Rounds to land\n\nThe highest review round each landed issue reached, across all its attempts "
      f"(1 = the first implementation passed).\n\n| Rounds | {la} | {lb} |\n|---:|---:|---:|")
    ra = Counter(int(r["rounds"]) for n, r in ia.items() if n in landed(ia))
    rb = Counter(int(r["rounds"]) for n, r in ib.items() if n in landed(ib))
    for k in sorted(set(ra) | set(rb)):
        P(f"| {k} | {ra[k]} | {rb[k]} |")
    # From §4's abandonment table, not the attempts column: an attempt whose files a later attempt
    # overwrote leaves no implement row, so deepseek-v4-flash's #27 reads as "1 attempt" despite
    # three abandonments.
    def abandoned(t):
        rows = next((v for k, v in t.items() if "abandoned" in k), [[]])
        return {int(r[0]) for r in rows[1:] if r and r[0].isdigit()}
    xa, xb = abandoned(ta), abandoned(tb)
    P(f"| **landed on the first attempt** | **{len(set(landed(ia)) - xa)}** | **{len(set(landed(ib)) - xb)}** |")
    P(f"| abandoned at least once | {len(xa)} ({', '.join('#%d' % n for n in sorted(xa))}) | {len(xb)} ({', '.join('#%d' % n for n in sorted(xb))}) |")

    both = [(n, num(ib[n]["$ cost"]) / num(ia[n]["$ cost"])) for n in sorted(set(landed(ia)) & set(landed(ib)))]
    both.sort(key=lambda t: t[1])
    med = both[len(both) // 2][1] if len(both) % 2 else (both[len(both) // 2 - 1][1] + both[len(both) // 2][1]) / 2
    P(f"\nPer-issue cost ratio ({lb} ÷ {la}) over the {len(both)} issues both landed: median **{med:.1f}×**, "
      f"lowest {both[0][1]:.1f}× (#{both[0][0]}), highest {both[-1][1]:.1f}× (#{both[-1][0]}).")

    P(f"\n### Per issue\n\n| # | Issue | {la} $ | {lb} $ | ratio | {la} rounds | {lb} rounds | {la} attempts | {lb} attempts |\n|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for n in sorted(set(ia) | set(ib)):
        ra_, rb_ = ia.get(n, {}), ib.get(n, {})
        x, y = num(ra_.get("$ cost", "—")), num(rb_.get("$ cost", "—"))
        ratio = f"{y / x:.1f}×" if x and y is not None else "—"
        P(f"| {n} | {(ra_ or rb_).get('issue', '')} | {ra_.get('$ cost', '—')} | {rb_.get('$ cost', '—')} | {ratio} | "
          f"{ra_.get('rounds', '—')} | {rb_.get('rounds', '—')} | {ra_.get('attempts', '—')} | {rb_.get('attempts', '—')} |")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verdict engine for tools/query-robustness.sh — compares one shape output
against one expectation and prints `<VERDICT>\t<detail>`.

Usage: compare.py <expect-spec> <shape.out> [truth.out]

Expect specs (the `expect` column of cases.tsv):
  rows:N            exactly N data rows
  value:k=v;k=v     exactly one data row; named columns match (numeric tol 0.02)
  truth_range       compare columns peak, integral against the truth file's row
  truth_series      compare the (minute -> concurrent) map against the truth file
  unique:col        every value of <col> distinct (row-identity check)
  record            no assertion; always OK (documentation runs)

Exit 0 always (the harness reads the verdict line); files are TSVWithNames.
"""
from __future__ import annotations

import sys


def read_tsv(path: str) -> tuple[list[str], list[list[str]]]:
    with open(path, encoding="utf-8") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.rstrip("\n") != ""]
    if not lines:
        return [], []
    header = lines[0].split("\t")
    return header, [ln.split("\t") for ln in lines[1:]]


def is_num(s: str) -> bool:
    try:
        float(s)
        return True
    except ValueError:
        return False


def same(a: str, b: str) -> bool:
    if is_num(a) and is_num(b):
        fa, fb = float(a), float(b)
        return abs(fa - fb) <= max(0.02, 1e-6 * max(abs(fa), abs(fb)))
    return a == b


def col(header: list[str], rows: list[list[str]], name: str, i: int) -> str:
    return rows[i][header.index(name)]


def main() -> None:
    spec, shape_path = sys.argv[1], sys.argv[2]
    truth_path = sys.argv[3] if len(sys.argv) > 3 else None
    header, rows = read_tsv(shape_path)

    kind, _, arg = spec.partition(":")

    if kind == "record":
        print(f"OK\trecorded {len(rows)} row(s)")

    elif kind == "rows":
        want = int(arg)
        if len(rows) == want:
            print(f"OK\t{len(rows)} row(s) as expected")
        else:
            head = "; ".join("|".join(r) for r in rows[:2])
            print(f"MISMATCH\texpected {want} row(s), got {len(rows)}: {head}")

    elif kind == "value":
        want = dict(kv.split("=", 1) for kv in arg.split(";"))
        if len(rows) != 1:
            print(f"MISMATCH\texpected 1 row, got {len(rows)}")
            return
        bad = []
        for k, v in want.items():
            got = col(header, rows, k, 0)
            if not same(got, v):
                bad.append(f"{k}: expected {v}, got {got}")
        if bad:
            print("MISMATCH\t" + "; ".join(bad))
        else:
            print("OK\t" + ", ".join(f"{k}={v}" for k, v in want.items()))

    elif kind == "truth_range":
        theader, trows = read_tsv(truth_path)
        bad = []
        for k in ("peak", "integral"):
            got = col(header, rows, k, 0) if rows else "(no row)"
            exp = col(theader, trows, k, 0) if trows else "(no row)"
            if got == "(no row)" or exp == "(no row)" or not same(got, exp):
                bad.append(f"{k}: truth {exp}, shape {got}")
        if bad:
            print("MISMATCH\t" + "; ".join(bad))
        else:
            print(
                "OK\tpeak/integral match truth "
                f"(peak={col(theader, trows, 'peak', 0)}, "
                f"integral={col(theader, trows, 'integral', 0)})"
            )

    elif kind == "truth_series":
        theader, trows = read_tsv(truth_path)
        got = {r[header.index("minute")]: float(r[header.index("concurrent")]) for r in rows}
        exp = {r[theader.index("minute")]: float(r[theader.index("concurrent")]) for r in trows}
        diffs = []
        for m in sorted(set(got) | set(exp)):
            g, e = got.get(m), exp.get(m)
            if g is None or e is None or abs(g - e) > 1e-9:
                diffs.append(f"{m}: truth {e}, shape {g}")
        if diffs:
            shown = "; ".join(diffs[:4])
            more = f" (+{len(diffs) - 4} more)" if len(diffs) > 4 else ""
            print(f"MISMATCH\t{len(diffs)}/{len(set(got) | set(exp))} minutes differ: {shown}{more}")
        else:
            print(f"OK\tall {len(exp)} minutes match truth")

    elif kind == "unique":
        vals = [r[header.index(arg)] for r in rows]
        dupes = sorted({v for v in vals if vals.count(v) > 1})
        if dupes:
            print(f"MISMATCH\tduplicate {arg} value(s) in result: {', '.join(dupes)}")
        else:
            print(f"OK\tall {len(vals)} {arg} values distinct")

    else:
        print(f"MISMATCH\tunknown expect kind: {kind}")


if __name__ == "__main__":
    main()

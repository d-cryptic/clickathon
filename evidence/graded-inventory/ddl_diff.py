#!/usr/bin/env python3
"""Diff normalized DDL between the repo-rendered scratch db and the graded db.

Normalization: strip db qualifiers, backticks, Shared* engine prefix + its
zk-path args, UUIDs, and collapse whitespace. Anything left different is drift.
"""
import re
import subprocess
import sys

ROOT = "/Users/barun/.superconductor/worktrees/clickathon-project/sc-diamagnetic-fluxon-6245"


def q(sql: str, cloud: bool) -> str:
    cmd = [f"{ROOT}/tools/ch"] + (["-c"] if cloud else []) + [sql]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def fetch(db: str, cloud: bool) -> dict[str, str]:
    out = q(
        f"SELECT name, create_table_query FROM system.tables "
        f"WHERE database='{db}' ORDER BY name FORMAT TSVRaw",
        cloud,
    )
    result = {}
    for line in out.splitlines():
        if "\t" not in line:
            continue
        name, ddl = line.split("\t", 1)
        result[name] = ddl
    return result


def norm(ddl: str, db: str) -> str:
    s = ddl
    s = s.replace("`", "")
    s = re.sub(rf"\b{re.escape(db)}\.", "", s)
    # Shared engines: SharedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}'[, ver]) -> MergeTree[(ver)]
    def shared(m: re.Match) -> str:
        eng, args = m.group(1), m.group(2)
        parts = [a.strip() for a in args.split(",")]
        extra = [a for a in parts if "clickhouse/tables" not in a and a != "'{replica}'"]
        return f"{eng}({', '.join(extra)})" if extra else eng

    s = re.sub(r"Shared(\w*MergeTree)\(([^)]*)\)", shared, s)
    s = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "UUID", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def settings_split(s: str) -> tuple[str, set[str]]:
    m = re.search(r" SETTINGS (.+)$", s)
    if not m:
        return s, set()
    body = s[: m.start()]
    settings = {x.strip() for x in m.group(1).split(",")}
    return body, settings


scratch = fetch("inv_drift", cloud=False)
cloud_objs = fetch("sonyliv", cloud=True)

names = sorted(set(scratch) | set(cloud_objs))
clean, drifted = [], []
for name in names:
    if name not in scratch:
        drifted.append((name, "ONLY ON CLOUD", "", ""))
        continue
    if name not in cloud_objs:
        drifted.append((name, "ONLY IN REPO RENDER", "", ""))
        continue
    a = norm(scratch[name], "inv_drift")
    b = norm(cloud_objs[name], "sonyliv")
    if a == b:
        clean.append(name)
        continue
    body_a, set_a = settings_split(a)
    body_b, set_b = settings_split(b)
    if body_a == body_b:
        drifted.append((name, "SETTINGS ONLY", str(set_a - set_b), str(set_b - set_a)))
    else:
        drifted.append((name, "BODY DIFFERS", body_a, body_b))

print(f"identical after normalization: {len(clean)}")
for n in clean:
    print(f"  = {n}")
print(f"\ndrifted: {len(drifted)}")
for n, kind, a, b in drifted:
    print(f"\n!! {n} — {kind}")
    if kind == "BODY DIFFERS":
        print(f"   repo : {a[:600]}")
        print(f"   cloud: {b[:600]}")
    elif kind == "SETTINGS ONLY":
        print(f"   repo-only settings : {a}")
        print(f"   cloud-only settings: {b}")

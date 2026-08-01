#!/usr/bin/env python3
"""Generate the explicit-state variant SQL files from the shipped derivation.

Each variant is sql/30_build_intervals.sql byte-for-byte except the stated,
anchored replacements below — the same discipline as evidence/adversarial/
(sed-templated variants) and evidence/liveness/fail-closed-variant.sql.
Anchors are exact strings from the shipped file; a failed anchor raises, so a
future edit to 30_build_intervals.sql cannot silently produce a stale variant.

Variants (doubts/12 · T8):
  baseline          shipped derivation, retargeted to the scratch DB only
  v1_transitions    AppBackgrounded closes immediately -> next AppForegrounded
                    reopens; unclosed bg stays closed to run end; bg state
                    carries across runs; tail capped at the next bg
  v1_shipped_tail   v1 minus the tail cap — isolates how much of v1 is the
                    tail rule vs the windows
  v5a_to_run_end    v1 minus the carry-across-runs rule — unclosed bg to run
                    end only (the light reading of "stay backgrounded")
  v5b_next_event    unclosed bg treated as a blip: closed at the next event
  v5c_next_heartbeat unclosed bg closed at the next VideoHeartbeat
  v2_union          gaps AND explicit events, whichever fires first: bg/fg no
                    longer renew liveness (so a bg-bridged silence is a gap
                    again) + the v1 windows + capped tail
  v3_explicit_only  gaps ignored entirely (one run per session): only explicit
                    pause/resume + bg/fg windows cut the session span
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = (ROOT / "sql" / "30_build_intervals.sql").read_text()
OUT = Path(__file__).resolve().parent / "sql"
DB = "exs_q12"

# ---------------------------------------------------------------- anchors ---
A_RESUMES = (
    "            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), "
    "event = 'resume')) AS resumes,\n"
)
A_ARRAYS = A_RESUMES + (
    "            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), "
    "event_type = 'AppBackgrounded')) AS bgs,\n"
    "            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), "
    "event_type = 'AppForegrounded')) AS fgs,\n"
    "            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), "
    "event_type = 'VideoHeartbeat')) AS hbs,\n"
)

B_RUNS = "            video_session_id, is_open,\n            pauses, resumes, dim_events,\n"
B_RUNS_NEW = (
    "            video_session_id, is_open,\n"
    "            pauses, resumes, bgs, fgs, hbs, dim_events,\n"
)

C_WINDOWED = (
    "        SELECT\n            video_session_id, is_open,\n"
    "            dim_events,\n            run[1]              AS run_start,\n"
)
C_WINDOWED_NEW = (
    "        SELECT\n            video_session_id, is_open,\n"
    "            dim_events, bgs,\n            run[1]              AS run_start,\n"
)

D_OPEN = "            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(\n"
D_OPEN_NEW = "            arrayFilter(w -> w.2 > w.1, arraySort(arrayConcat(arrayMap(\n"
D_CLOSE = (
    "                arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)\n"
    "            ))) AS pause_windows\n"
)

UNCLOSED = {
    "run_end": "run[length(run)]",
    "next_event": (
        "if(arrayFirst(x -> x > b, run) = 0, run[length(run)], "
        "arrayFirst(x -> x > b, run))"
    ),
    "next_hb": (
        "if(arrayFirst(x -> x > b, hbs) = 0, run[length(run)], "
        "arrayFirst(x -> x > b, hbs))"
    ),
}

CARRY_IN = (
    ",\n"
    "                -- backgrounded when the run starts (bg in an earlier run,\n"
    "                -- no fg yet): excluded until the first fg in this run\n"
    "                if((arrayLast(x -> x < run[1], bgs) = 0)\n"
    "                     OR (arrayLast(x -> x < run[1], fgs) >= arrayLast(x -> x < run[1], bgs)),\n"
    "                   CAST([], 'Array(Tuple(UInt32, UInt32))'),\n"
    "                   [(toUInt32(run[1]),\n"
    "                     if(arrayFirst(x -> x >= run[1], fgs) = 0,\n"
    "                        toUInt32(run[length(run)]),\n"
    "                        least(arrayFirst(x -> x >= run[1], fgs), toUInt32(run[length(run)]))))])\n"
)


def d_close_new(unclosed: str, carry_in: bool) -> str:
    text = (
        "                arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)\n"
        "                ),\n"
        "                -- AppBackgrounded closes immediately; the window ends at the\n"
        "                -- next AppForegrounded (>= : a same-second fg yields a\n"
        "                -- zero-length window, dropped by the outer filter — the same\n"
        "                -- tie rule the pause windows use). Unclosed bg: see below.\n"
        "                arrayMap(\n"
        "                    b -> (b, least(\n"
        "                            if(arrayFirst(x -> x >= b, fgs) = 0,\n"
        f"                               {unclosed},\n"
        "                               arrayFirst(x -> x >= b, fgs)),\n"
        "                            run[length(run)])),\n"
        "                    arrayFilter(b -> (b >= run[1]) AND (b < run[length(run)]), bgs)\n"
        "                )"
    )
    text += CARRY_IN if carry_in else "\n"
    return text + "            ))) AS pause_windows\n"


E_TAIL = (
    "        toDateTime64(seg.2 + if(seg.2 = run_end, TAIL_S, 0), 3) AS interval_end,\n"
)
E_TAIL_NEW = (
    "        -- Tail capped at the next AppBackgrounded (>= : a bg in the same\n"
    "        -- second as the run end kills the tail entirely): closing\n"
    "        -- \"immediately\" cannot then hand back 60 s of grace.\n"
    "        toDateTime64(seg.2 + if(seg.2 = run_end,\n"
    "            if(arrayFirst(x -> x >= toUInt32(run_end), bgs) = 0, toUInt32(TAIL_S),\n"
    "               least(toUInt32(TAIL_S), arrayFirst(x -> x >= toUInt32(run_end), bgs) - toUInt32(run_end))),\n"
    "            0), 3) AS interval_end,\n"
)

F_TS = (
    "            arraySort(groupArray(toUnixTimestamp(event_timestamp)))"
    "                    AS ts,\n"
)
F_TS_NEW = (
    "            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),\n"
    "                      event_type NOT IN ('AppBackgrounded', 'AppForegrounded')))  AS ts,\n"
)

G_SPLIT = (
    "            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), "
    "ts, arrayEnumerate(ts))) AS run\n"
)
G_SPLIT_NEW = "            arrayJoin([ts]) AS run\n"


def replace(text: str, old: str, new: str, what: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"anchor not found exactly once ({what}): {old[:80]!r}")
    return text.replace(old, new)


def build(name, *, arrays=False, unclosed=None, carry_in=False,
          tail_bg_capped=False, ts_no_bgfg=False, no_gap_split=False) -> None:
    sql = SRC
    sql = replace(sql, "INSERT INTO session_intervals",
                  f"INSERT INTO {DB}.si_{name}", "insert target")
    sql = replace(sql, "FROM ev_raw", "FROM default.ev_raw", "source table")
    if arrays:
        sql = replace(sql, A_RESUMES, A_ARRAYS, "per_session arrays")
        sql = replace(sql, B_RUNS, B_RUNS_NEW, "runs carry")
        sql = replace(sql, C_WINDOWED, C_WINDOWED_NEW, "windowed carry")
    if unclosed is not None:
        sql = replace(sql, D_OPEN, D_OPEN_NEW, "windows concat open")
        sql = replace(sql, D_CLOSE, d_close_new(UNCLOSED[unclosed], carry_in),
                      "windows concat close")
    if tail_bg_capped:
        sql = replace(sql, E_TAIL, E_TAIL_NEW, "tail cap")
    if ts_no_bgfg:
        sql = replace(sql, F_TS, F_TS_NEW, "ts allow-list")
    if no_gap_split:
        sql = replace(sql, G_SPLIT, G_SPLIT_NEW, "gap split removal")
    (OUT / f"{name}.sql").write_text(sql)
    print(f"wrote {OUT / f'{name}.sql'}")


build("baseline")
build("v1_transitions", arrays=True, unclosed="run_end", carry_in=True,
      tail_bg_capped=True)
build("v1_shipped_tail", arrays=True, unclosed="run_end", carry_in=True)
build("v5a_to_run_end", arrays=True, unclosed="run_end", tail_bg_capped=True)
build("v5b_next_event", arrays=True, unclosed="next_event", tail_bg_capped=True)
build("v5c_next_heartbeat", arrays=True, unclosed="next_hb", tail_bg_capped=True)
build("v2_union", arrays=True, unclosed="run_end", carry_in=True,
      tail_bg_capped=True, ts_no_bgfg=True)
build("v3_explicit_only", arrays=True, unclosed="run_end", carry_in=True,
      tail_bg_capped=True, no_gap_split=True)

# evidence/clickstack — signed-in verification of the hosted dashboards

> **Summary:** Evidence for the 2026-08-01 ClickStack session: all 53 tiles across all 7
> hosted HyperDX dashboards executed signed-in through HyperDX's own query path
> (tile-verification-2026-08-01.txt), plus a data-faithful rendering of the headline and
> user-level story (dashboard-preview.{html,png}) captured live from the graded service's
> serving views. Pixel screenshots of the HyperDX UI itself require console SSO — a human
> login the Cloud API key cannot perform; this directory holds the closest verifiable proxy.

| File | What it is |
|---|---|
| `tile-verification-2026-08-01.txt` | Every tile of every dashboard executed via the clickstack MCP `query_tile` (the exact query HyperDX runs when the tile renders), with the value each returned. Includes the user-source bug audit and the SonyLIV user-level build-out. |
| `dashboard-preview.png` | Headless-Chrome rendering of `dashboard-preview.html` — the headline three-curve comparison and the user-level sessions-vs-users gap, drawn from live read-only SELECTs against the same `sonyliv` serving views the tiles read. |
| `dashboard-preview.html` | The self-contained source of the PNG (regenerate: query + render script lives in the session worksheet trail; data is pipeline output, nothing hand-computed). |

**Why no HyperDX UI screenshots:** the hosted HyperDX authenticates through the ClickHouse
Cloud console (SSO). The API key used by `tools/clickstack-cloud.sh` and the clickstack MCP
drives the control plane and the query path — everything verifiable — but cannot mint a
browser session. Confirmed twice (2026-08-01, both sessions). A human with console access
can capture UI screenshots from the dashboard URLs in `docs/CLICKSTACK_DASHBOARDS.md`;
set the time range to **2026-07-14 → 2026-07-26** first (product dashboards) or a recent
range (pipeline health / query cost), and warm the service with `tools/ch -c "SELECT 1"`.

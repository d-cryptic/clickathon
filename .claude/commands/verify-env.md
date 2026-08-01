---
description: Confirm the stack is actually up and correctly configured before trusting anything.
---
Silent misconfiguration is the biggest time-sink in this stack. Check, in order:

1. `SELECT version()` — is it what we think? Cloud and local may differ.
2. `SELECT timezone()` — must be UTC.
3. Did the init scripts actually run? `SELECT name FROM system.tables WHERE database='default'` must
   list `ev_raw`, `content_dim`, `session_intervals`, `cc_minute_delta`. **A failed init script does
   NOT stop the container and `/api/health` still returns 200.**
4. `SELECT name FROM system.users` must list `agent_ro` and `web_ro`.
5. Confirm `agent_ro` has a real password: an empty password and the literal string `${AGENT_PASSWORD}`
   must BOTH be rejected (403).
6. `SELECT setting_name, value, max FROM system.settings_profile_elements WHERE user_name='agent_ro'`
   — the MAX constraints must be present.
7. If ClickStack is expected: OTLP must return 200 with the key and 401 without it.

Report a table of check | expected | actual | PASS/FAIL. Do not say "looks fine" without the values.

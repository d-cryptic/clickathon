# P6 failure — seed `20260802-69` (spec mode)

> Reproduce: `tools/property-test.sh --case 20260802-69`

## What disagreed

```
user tier != reference mirror on 125 cells:
  (1786812780, ('IPHONE', 'india', 21000002)): reference=1 cc_user_minute=0
  (1786812840, ('IPHONE', 'india', 21000002)): reference=1 cc_user_minute=0
  (1786812840, ('SONY_ANDROID_TV', 'india', 21000002)): reference=0 cc_user_minute=1
  (1786812900, ('IPHONE', 'india', 21000002)): reference=1 cc_user_minute=0
```

## Shrunk counterexample — 4 events (from 1963)

| session | ts (utc) | ms | event_type | event | dims (plat/ctry/cid/aud/sub/app/ply/user) |
|---|---|---|---|---|---|
| vs_20260802-69_08 | 16:53:12 | 1786812792900 | VideoHeartbeat | BufferEnd | ANDROID_PHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:53:16 | 1786812796999 | VideoHeartbeat | pause | ANDROID_PHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:53:25 | 1786812805900 | VideoHeartbeat | resume | IPHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:54:25 | 1786812865404 | VideoHeartbeat | speed-resume | SONY_ANDROID_TV/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |

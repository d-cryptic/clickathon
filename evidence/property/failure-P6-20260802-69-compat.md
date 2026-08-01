# P6 failure — seed `20260802-69` (compat mode)

> Reproduce: `tools/property-test.sh --case 20260802-69` with PROP_COMPAT=1

## What disagreed

```
user concurrency EXCEEDS session concurrency at 63 (minute, grain) cells (first 4): [((1786816020, ('IPHONE', 'india', 21000002)), 1, 0), ((1786814100, ('IPHONE', 'india', 21000002)), 1, 0), ((1786813260, ('IPHONE', 'india', 21000002)), 1, 0), ((1786813680, ('IPHONE', 'india', 21000002)), 1, 0)]
```

## Shrunk counterexample — 4 events (from 1963)

| session | ts (utc) | ms | event_type | event | dims (plat/ctry/cid/aud/sub/app/ply/user) |
|---|---|---|---|---|---|
| vs_20260802-69_08 | 16:53:12 | 1786812792900 | VideoHeartbeat | BufferEnd | ANDROID_PHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:53:16 | 1786812796999 | VideoHeartbeat | pause | ANDROID_PHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:53:25 | 1786812805900 | VideoHeartbeat | resume | IPHONE/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |
| vs_20260802-69_08 | 16:54:25 | 1786812865404 | VideoHeartbeat | speed-resume | SONY_ANDROID_TV/india/21000002/hin/bho/99.0.1/9.9.9/u20260802-69_10 |

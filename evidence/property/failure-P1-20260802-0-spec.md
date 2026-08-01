# P1 failure — seed `20260802-0` (spec mode)

> Reproduce: `tools/property-test.sh --case 20260802-0`

## What disagreed

```
intervals differ: reference 27 vs sql 21
  only in reference: [('vs_20260802-0_02', 'u20260802-0_4', 21000003, 'Mweb', 'india', '99.0.1', 'eng', 'bho', '9.9.9', 1786758643, 1786758703, 0), ('vs_20260802-0_02', 'u20260802-0_4', 21000003, 'Mweb', 'india', '99.0.1', 'eng', 'bho', '9.9.9', 1786759105, 1786759165, 0), ('vs_20260802-0_02', 'u20260802-0_4', 21000003, 'SONY_ANDROID_TV', 'india', '99.0.1', 'eng', 'bho', '9.9.9', 1786758600, 1786758600, 0), ('vs_20260802-0_03', 'u20260802-0_1', 21000002, 'IPHONE', 'IN', '99.0.1', 'unk', 'bho', '9.9.9', 1786804669, 1786804729, 0)]
  only in sql:       []
```

## Shrunk counterexample — 1 events (from 880)

| session | ts (utc) | ms | event_type | event | dims (plat/ctry/cid/aud/sub/app/ply/user) |
|---|---|---|---|---|---|
| vs_20260802-0_11 | 13:49:09 | 1786801749404 | VideoHeartbeat | AdResume | Mweb/nepal/-1/unk/unk/99.0.1/1.8.2/u20260802-0_5 |

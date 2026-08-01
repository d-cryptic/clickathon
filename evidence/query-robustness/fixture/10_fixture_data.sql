-- ============================================================================
-- evidence/query-robustness/fixture/10_fixture_data.sql — HOSTILE fixture data.
-- 18 designed session_intervals + a 4-row content catalog, every value chosen
-- to break one specific serving assumption. Loaded into a LOCAL scratch db
-- (default `robust`) by tools/query-robustness.sh setup — NEVER the graded db;
-- the throwIf below refuses to run there. Ground truth for every number is
-- hand-computable and re-derived independently by ../truth/range_truth.sql.
-- Canvas: 2026-06-01/02 UTC, far from the real data (2026-07-14..27).
-- ============================================================================

-- Refuse the graded database outright, before any statement that writes.
SELECT throwIf(currentDatabase() = 'sonyliv',
               'fixture refuses to run against the graded database');

-- Idempotent re-load: the fixture IS the entire content of these tables.
TRUNCATE TABLE session_intervals;
TRUNCATE TABLE content_dim;

-- ---------------------------------------------------------------------------
-- Content catalog. 103 carries a BLANK video_type; -1 is a REAL catalog row
-- whose id collides with the content display sentinel (ADR 0022 / rehearsal
-- R9). content_id 999 is deliberately ABSENT — the orphan.
-- ---------------------------------------------------------------------------
INSERT INTO content_dim (content_id, title, video_type, category) VALUES
    (101, 'Alpha Live',      'live', 'sports'),
    (102, 'Beta Movie',      'vod',  'movies'),
    (103, 'Gamma Blank',     '',     'misc'),
    (-1,  'Minus One Asset', 'live', 'sports');

-- ---------------------------------------------------------------------------
-- Intervals. Column order matches sql/10_intervals.sql. All is_open=0,
-- build_version=1. Hostile features, per row:
--   s01/s02/s03/s04  Hindi as four raw spellings (ADR 0011)
--   s05              same user as s01, concurrently, on a second platform
--   s06              REAL content_id = -1 (sentinel collision)
--   s07              platform is the literal string '*' (display-sentinel twin)
--   s08              content_id 999 — not in the catalog (orphan)
--   s09              platform case-twin 'android_phone' + Devanagari audio
--   s10              platform WEB_TV_RARE exists ONLY in hour 14 of day 1
--   s11              ends 14:59:59 — last minute of the hour (no close emitted)
--   s12              spans 4 hours (15:30-18:45) — middle-hour clipping
--   s13              ends exactly ON the hour boundary (20:00:00.000)
--   s14              crosses an hour boundary inside 60 s (20:59:30-21:00:30)
--   s15              lives entirely inside one minute (22:10:10-22:10:50)
--   s16              the only day-2 activity
--   s17              the first activity of the fixture (08:00)
--   s18              same user as s02, same platform, overlapping session
--
-- Hand-computed hour-10 truth (session grain, total): peak 8 @ 10:30,
-- integral 12,180 s. Per-platform hour-10 peaks: ANDROID_PHONE 4, IOS_PHONE 2,
-- WEB 1, '*' 1, android_phone 1 — sum 9 != 8 (peaks at different minutes).
-- Day-1 integral 33,000 s; hour-20 peak 1 tied at 20:00 and 20:59 (earliest
-- wins -> 20:00). Users at 10:30: 7 distinct across 8 sessions.
-- ---------------------------------------------------------------------------
INSERT INTO session_intervals
    (video_session_id, user_id, content_id, platform, country,
     app_version, audio_language, subtitle_language, player_version,
     interval_start, interval_end, is_open, build_version) VALUES
    ('s01','u01',101,'ANDROID_PHONE','india','1.0.0','hin','OFF','p1','2026-06-01 10:05:00.000','2026-06-01 10:25:00.000',0,1),
    ('s02','u02',101,'ANDROID_PHONE','india','1.0.0','HIN','OFF','p1','2026-06-01 10:10:00.000','2026-06-01 10:40:00.000',0,1),
    ('s03','u03',101,'IOS_PHONE','india','1.0.0','hin-hindi','OFF','p1','2026-06-01 10:10:00.000','2026-06-01 10:20:00.000',0,1),
    ('s04','u04',102,'WEB','india','1.0.0','hin-Hindi','OFF','p1','2026-06-01 10:15:00.000','2026-06-01 10:45:00.000',0,1),
    ('s05','u01',102,'IOS_PHONE','india','1.0.0','eng','OFF','p1','2026-06-01 10:15:00.000','2026-06-01 10:35:00.000',0,1),
    ('s06','u05',-1,'ANDROID_PHONE','india','1.0.0','tam','OFF','p1','2026-06-01 10:12:00.000','2026-06-01 10:50:00.000',0,1),
    ('s07','u06',101,'*','india','1.0.0','tel','OFF','p1','2026-06-01 10:20:00.000','2026-06-01 10:30:00.000',0,1),
    ('s08','u07',999,'ANDROID_PHONE','india','1.0.0','hin','OFF','p1','2026-06-01 10:22:00.000','2026-06-01 10:38:00.000',0,1),
    ('s09','u08',101,'android_phone','india','1.0.0','हिन्दी','OFF','p1','2026-06-01 10:30:00.000','2026-06-01 10:44:00.000',0,1),
    ('s10','u09',102,'WEB_TV_RARE','india','1.0.0','eng','OFF','p1','2026-06-01 14:05:00.000','2026-06-01 14:20:00.000',0,1),
    ('s11','u10',102,'ANDROID_PHONE','india','1.0.0','eng','OFF','p1','2026-06-01 14:00:00.000','2026-06-01 14:59:59.000',0,1),
    ('s12','u11',101,'IOS_TV','india','1.0.0','hin','OFF','p1','2026-06-01 15:30:00.000','2026-06-01 18:45:00.000',0,1),
    ('s13','u12',101,'WEB','india','1.0.0','eng','OFF','p1','2026-06-01 19:00:00.000','2026-06-01 20:00:00.000',0,1),
    ('s14','u13',101,'WEB','india','1.0.0','eng','OFF','p1','2026-06-01 20:59:30.000','2026-06-01 21:00:30.000',0,1),
    ('s15','u14',102,'IOS_PHONE','india','1.0.0','eng','OFF','p1','2026-06-01 22:10:10.000','2026-06-01 22:10:50.000',0,1),
    ('s16','u15',101,'ANDROID_PHONE','india','1.0.0','hin','OFF','p1','2026-06-02 09:00:00.000','2026-06-02 09:30:00.000',0,1),
    ('s17','u16',102,'WEB','india','1.0.0','eng','OFF','p1','2026-06-01 08:00:00.000','2026-06-01 08:10:00.000',0,1),
    ('s18','u02',101,'ANDROID_PHONE','india','1.0.0','HIN','OFF','p1','2026-06-01 10:30:00.000','2026-06-01 10:35:00.000',0,1);

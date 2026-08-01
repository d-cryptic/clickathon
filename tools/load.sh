#!/usr/bin/env bash
# tools/load.sh — load the provided CSVs into ev_raw + content_dim.
#
# Streams the file over stdin rather than using file(). Two reasons:
#   1. file() only reads from user_files_path — a bind-mounted /data gives
#      Code: 291 DATABASE_ACCESS_DENIED.
#   2. The GRADED target is ClickHouse Cloud, where there is no local file at all.
#      stdin works identically against local and Cloud, so we load the unseen day
#      exactly the way we tested.
#
# event_timestamp / session_start_epoch are epoch MILLIS in the source.
set -euo pipefail
[ -f .env ] && set -a && . ./.env && set +a

RAW="${1:-data/ch-hackathon-raw-data.csv}"
CONTENT="${2:-data/ch-hackathon-content-data.csv}"
TARGET="${TARGET:-local}"          # TARGET=cloud tools/load.sh

RAW_COLS='content_id Int64, video_session_id String, user_id String, event_type String, event String, event_timestamp UInt64, platform String, app_version String, country String, audio_language String, subtitle_language String, player_version String, session_start_epoch UInt64'
CONTENT_COLS='content_id Int64, title String, video_type String, category String'

run() {  # run <sql> ; CSV arrives on stdin
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body \
      "https://${CH_HOST}:${CH_PORT}/?database=${CH_DATABASE}&query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
  else
    docker exec -i ch clickhouse-client --query "$1"
  fi
}

[ -f "$CONTENT" ] || { echo "missing $CONTENT"; exit 1; }
[ -f "$RAW" ]     || { echo "missing $RAW"; exit 1; }

echo "loading content_dim from $CONTENT ..."
run "INSERT INTO content_dim SELECT content_id, title, video_type, category FROM input('$CONTENT_COLS') FORMAT CSVWithNames" < "$CONTENT"

echo "loading ev_raw from $RAW ..."
run "INSERT INTO ev_raw SELECT content_id, video_session_id, user_id, event_type, event, toDateTime64(event_timestamp/1000, 3), platform, app_version, country, audio_language, subtitle_language, player_version, toDateTime64(session_start_epoch/1000, 3) FROM input('$RAW_COLS') FORMAT CSVWithNames" < "$RAW"

docker exec -i ch clickhouse-client -q "SELECT 'ev_raw' AS t, count() AS rows FROM ev_raw UNION ALL SELECT 'content_dim', count() FROM content_dim FORMAT PrettyCompact"

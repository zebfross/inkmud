#!/usr/bin/env bash
# List players' feedback notes, newest first, with what they were looking at.
#   scripts/feedback.sh          all notes
#   scripts/feedback.sh 5        the newest 5
#   scripts/feedback.sh 5 short  without the chronicle context
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${DB_PATH:-data/inkmud.db}"
LIMIT="${1:--1}"
if [ "${2:-}" = "short" ]; then
  sqlite3 -separator ' | ' "$DB" \
    "select id, datetime(at, 'localtime'), player, room_name, text from feedback order by id desc limit $LIMIT"
else
  sqlite3 "$DB" "select '#' || id || '  ' || datetime(at, 'localtime') || '  ' || player || ' in ' || coalesce(nullif(room_name,''), '?') || char(10) || text || char(10) || '--- context ---' || char(10) || context || char(10) from feedback order by id desc limit $LIMIT"
fi

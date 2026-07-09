#!/usr/bin/env bash
# add-asset-task.sh — register an approved #asset task into the Slack
# "Tasks(Asset)" list and reply the result back into the thread.
#
# Invoked by n8n (SSH) when the user clicks "Yes" on the prompt:
#   add-asset-task.sh <channel> <thread_ts> <task_text>
#
# Talks to the Slack Lists API directly (does NOT depend on slack-tasks.sh,
# whose column constants drift when the list schema changes).
#
# Optional: set ASSET_TASK_GUBUN to one of "MVP" | "Dev-Only" | "고도화" to
# also set the 구분(select) column. Default: leave 구분 empty (human fills it).
#
# Auth: bot token (xoxb-…) from $SLACK_CANVAS_TOKEN_FILE
#       (default ~/.claude/.slack-canvas-token). Scopes: chat:write, lists:write.
set -euo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

TOKEN_FILE="${SLACK_CANVAS_TOKEN_FILE:-$HOME/.claude/.slack-canvas-token}"
API="https://slack.com/api"

# --- Tasks(Asset) list schema (verified live via files.info) ---------------
LIST_ID="F0B9C3J3J48"
NAME_COL="name"                 # primary text column (이름)
GUBUN_COL="Col0BC83VQMKN"       # 구분 (select)
# 구분 options: MVP=OptF1L98Q24 · Dev-Only=Opt82HRKTUC · 고도화=OptPQU2UIU5
declare -A GUBUN_OPT=( ["MVP"]="OptF1L98Q24" ["Dev-Only"]="Opt82HRKTUC" ["고도화"]="OptPQU2UIU5" )

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <channel> <thread_ts> <task_text>"
CHANNEL="$1"; THREAD_TS="$2"; TASK="$3"

[ -f "$TOKEN_FILE" ] || die "token file not found: $TOKEN_FILE"
TOK="$(tr -d '\n' < "$TOKEN_FILE")"
[ -n "$TOK" ] || die "empty token in $TOKEN_FILE"
command -v jq >/dev/null || die "jq is required"

api() { # api <method> <json-payload>
  printf '%s' "$2" | curl -s -X POST \
    -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data @- "$API/$1"
}

# --- build the item cells: name (+ optional 구분) ---------------------------
CELLS="$(jq -nc --arg ncol "$NAME_COL" --arg name "$TASK" \
          '[{column_id:$ncol, text:$name}]')"
GUBUN_LABEL=""
if [ -n "${ASSET_TASK_GUBUN:-}" ]; then
  opt="${GUBUN_OPT[$ASSET_TASK_GUBUN]:-}"
  [ -n "$opt" ] || die "ASSET_TASK_GUBUN must be one of: MVP | Dev-Only | 고도화"
  CELLS="$(jq -nc --argjson c "$CELLS" --arg gcol "$GUBUN_COL" --arg opt "$opt" \
            '$c + [{column_id:$gcol, select:[$opt]}]')"
  GUBUN_LABEL=" (구분: $ASSET_TASK_GUBUN)"
fi

# 1) create the list item
CREATE_PAYLOAD="$(jq -nc --arg list "$LIST_ID" --argjson cells "$CELLS" \
                   '{list_id:$list, cells:$cells}')"
CREATE_RES="$(api slackLists.items.create "$CREATE_PAYLOAD")"
[ "$(printf '%s' "$CREATE_RES" | jq -r '.ok')" = "true" ] \
  || die "list add failed: $(printf '%s' "$CREATE_RES" | jq -c '{ok,error,needed,provided}')"

# 2) reply the registered task back into the thread
REPLY="$(jq -nc --arg c "$CHANNEL" --arg t "$THREAD_TS" --arg task "$TASK" --arg g "$GUBUN_LABEL" \
  '{channel:$c, thread_ts:$t, text:("✅ Tasks(Asset)에 등록했습니다" + $g + "\n• " + $task)}')"
REPLY_RES="$(api chat.postMessage "$REPLY")"
[ "$(printf '%s' "$REPLY_RES" | jq -r '.ok')" = "true" ] \
  || die "thread reply failed: $(printf '%s' "$REPLY_RES" | jq -c '{ok,error}')"

echo "ok: registered \"$TASK\"$GUBUN_LABEL"

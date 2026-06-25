#!/usr/bin/env bash
# add-asset-task.sh — register an approved #asset task into the Slack
# "Tasks(Asset)" list and reply the result back into the thread.
#
# Invoked by n8n (SSH) when the user clicks "Yes" on the prompt:
#   add-asset-task.sh <channel> <thread_ts> <task_text>
#
# Auth: bot token (xoxb-…) from $SLACK_CANVAS_TOKEN_FILE
#       (default ~/.claude/.slack-canvas-token). Scopes: chat:write, lists:write.
set -euo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

TOKEN_FILE="${SLACK_CANVAS_TOKEN_FILE:-$HOME/.claude/.slack-canvas-token}"
SLACK_TASKS="$HOME/.claude/plugins/marketplaces/hackartists/skills/slack-tasks/slack-tasks.sh"
API="https://slack.com/api"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <channel> <thread_ts> <task_text>"
CHANNEL="$1"; THREAD_TS="$2"; TASK="$3"

[ -f "$TOKEN_FILE" ] || die "token file not found: $TOKEN_FILE"
TOK="$(tr -d '\n' < "$TOKEN_FILE")"
[ -n "$TOK" ] || die "empty token in $TOKEN_FILE"
command -v jq >/dev/null || die "jq is required"
[ -x "$SLACK_TASKS" ] || die "slack-tasks.sh not found/executable: $SLACK_TASKS"

# 1) add to the Tasks(Asset) list (구분=기획). Capture output for the reply.
ADD_OUT="$("$SLACK_TASKS" add 기획 "$TASK" 2>&1)" || die "slack-tasks add failed: $ADD_OUT"

# 2) reply the registered task back into the thread.
REPLY="$(jq -n --arg c "$CHANNEL" --arg t "$THREAD_TS" --arg task "$TASK" \
  '{channel:$c, thread_ts:$t,
    text:("✅ Tasks(Asset)에 등록했습니다 (구분: 기획)\n• " + $task)}')"

RESP="$(printf '%s' "$REPLY" | curl -s -X POST \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @- "$API/chat.postMessage")"

[ "$(printf '%s' "$RESP" | jq -r '.ok')" = "true" ] \
  || die "thread reply failed: $(printf '%s' "$RESP" | jq -c '{ok,error}')"

echo "ok: registered \"$TASK\""

#!/usr/bin/env bash
# asset-task-action.sh — handle a Yes/No button click from the #asset task prompt.
#
# Invoked by n8n (SSH) from the Slack interactivity webhook:
#   asset-task-action.sh <action_id> <channel> <thread_ts> <task_b64> <response_url>
#
#   action_id : "asset_task_yes" | "asset_task_no"
#   task_b64  : the task title, base64-encoded (avoids shell-quoting issues
#               with spaces / Korean / punctuation)
#   response_url: Slack response_url from the interaction payload (used to
#               replace the original message so the buttons can't be re-clicked)
#
# On Yes: register the task (add-asset-task.sh) then disable the buttons.
# On No : just disable the buttons.
set -euo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

DIR="$(cd "$(dirname "$0")" && pwd)"
MINER="U03QHDMCVB2"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 4 ] || die "usage: $0 <action_id> <channel> <thread_ts> <task_b64> [response_url]"
ACTION="$1"; CHANNEL="$2"; THREAD_TS="$3"; TASK_B64="$4"; RESPONSE_URL="${5:-}"
command -v jq >/dev/null || die "jq is required"

TASK="$(printf '%s' "$TASK_B64" | base64 -d)"

# Replace the original prompt message (removes the Yes/No buttons).
disable_buttons() { # <text>
  [ -n "$RESPONSE_URL" ] || return 0
  jq -n --arg t "$1" \
    '{replace_original:true, text:$t,
      blocks:[{type:"section",text:{type:"mrkdwn",text:$t}}]}' \
    | curl -s -X POST -H "Content-Type: application/json" \
        --data @- "$RESPONSE_URL" >/dev/null || true
}

case "$ACTION" in
  asset_task_yes)
    "$DIR/add-asset-task.sh" "$CHANNEL" "$THREAD_TS" "$TASK"
    disable_buttons "✅ <@$MINER> 업무로 등록했습니다: $TASK"
    ;;
  *)
    disable_buttons "❎ 업무로 등록하지 않았습니다: $TASK"
    ;;
esac

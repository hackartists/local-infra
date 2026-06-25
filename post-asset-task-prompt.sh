#!/usr/bin/env bash
# post-asset-task-prompt.sh — post an interactive "register as task?" prompt
# as a threaded reply in the #asset channel, cc Miner, with Yes/No buttons.
#
# The button payload carries {channel, thread_ts, task} as JSON so the n8n
# interactivity webhook can register the task without any extra state.
#
# Usage:
#   post-asset-task-prompt.sh <channel> <thread_ts> <task_text> [reason]
#
# Auth: reads a Slack bot token (xoxb-…) from $SLACK_CANVAS_TOKEN_FILE
#       (default ~/.claude/.slack-canvas-token). Scopes needed: chat:write.
#
# Prints the posted message ts on success.
set -euo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

TOKEN_FILE="${SLACK_CANVAS_TOKEN_FILE:-$HOME/.claude/.slack-canvas-token}"
MINER="U03QHDMCVB2"        # Miner — always cc'd on the prompt
API="https://slack.com/api"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: $0 <channel> <thread_ts> <task_text> [reason]"
CHANNEL="$1"; THREAD_TS="$2"; TASK="$3"; REASON="${4:-}"

[ -f "$TOKEN_FILE" ] || die "token file not found: $TOKEN_FILE"
TOK="$(tr -d '\n' < "$TOKEN_FILE")"
[ -n "$TOK" ] || die "empty token in $TOKEN_FILE"
command -v jq >/dev/null || die "jq is required"

# Everything the interactivity handler needs, embedded in the button value
# (Slack caps button value at 2000 chars; task names are short).
VALUE="$(jq -nc --arg c "$CHANNEL" --arg t "$THREAD_TS" --arg task "$TASK" \
          '{channel:$c, thread_ts:$t, task:$task}')"

PAYLOAD="$(jq -n \
  --arg channel "$CHANNEL" \
  --arg thread_ts "$THREAD_TS" \
  --arg miner "$MINER" \
  --arg task "$TASK" \
  --arg reason "$REASON" \
  --arg value "$VALUE" \
  '{
    channel: $channel,
    thread_ts: $thread_ts,
    text: ("cc <@" + $miner + "> 업무로 등록할까요?"),
    blocks: [
      { type: "section",
        text: { type: "mrkdwn",
                text: ( "*업무 내용*\n" + $task
                        + (if $reason != "" then "\n\n*근거*\n" + $reason else "" end)
                        + "\n\ncc <@" + $miner + ">" ) } },
      { type: "actions",
        block_id: "asset_task_actions",
        elements: [
          { type: "button", action_id: "asset_task_yes", style: "primary",
            text: { type: "plain_text", text: "Yes", emoji: true }, value: $value },
          { type: "button", action_id: "asset_task_no", style: "danger",
            text: { type: "plain_text", text: "No", emoji: true }, value: $value }
        ] }
    ]
  }')"

RESP="$(printf '%s' "$PAYLOAD" | curl -s -X POST \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @- "$API/chat.postMessage")"

if [ "$(printf '%s' "$RESP" | jq -r '.ok')" != "true" ]; then
  printf '%s' "$RESP" | jq '{ok, error, response_metadata}' >&2
  exit 1
fi
printf '%s\n' "$(printf '%s' "$RESP" | jq -r '.ts')"

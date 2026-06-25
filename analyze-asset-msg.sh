#!/usr/bin/env zsh
# analyze-asset-msg.sh — analyze a #asset channel message with the Claude CLI and,
# if it should become a task, post an interactive Yes/No prompt in the thread.
#
# Invoked by n8n (SSH) on every new top-level #asset message:
#   analyze-asset-msg.sh <channel> <ts> [thread_ts]
#
# Design: the Claude CLI only ANALYZES (using the Chrome MCP to open any links)
# and emits a one-line decision JSON. This script then deterministically posts
# the Yes/No prompt with the bot token — so posting never depends on the agent
# having shell/Slack tool permissions.
#
#   Claude prints, as its LAST line:  DECISION {"is_task":bool,"title":"…","reason":"…"}
set -uo pipefail
source "$HOME/.zshrc" 2>/dev/null || true
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

CHANNEL="${1:?usage: analyze-asset-msg.sh <channel> <ts> [thread_ts]}"
TS="${2:?usage: analyze-asset-msg.sh <channel> <ts> [thread_ts]}"
THREAD_TS_IN="${3:-}"

# Only analyze top-level messages: skip thread replies.
if [ -n "$THREAD_TS_IN" ] && [ "$THREAD_TS_IN" != "$TS" ]; then
  echo "skip: thread reply (thread_ts=$THREAD_TS_IN ts=$TS)"
  exit 0
fi

REPO="/Users/hackartist/data/devel/github.com/hackartists/local-infra"
TOKEN_FILE="${SLACK_CANVAS_TOKEN_FILE:-$HOME/.claude/.slack-canvas-token}"
TOK="$(tr -d '\n' < "$TOKEN_FILE")"

WORKDIR="/tmp/asset/$TS"
mkdir -p "$WORKDIR"; cd "$WORKDIR"

# Fetch the message so the agent does not have to hunt for it.
MSG_JSON="$(curl -s -G -H "Authorization: Bearer $TOK" \
  --data-urlencode "channel=$CHANNEL" \
  --data-urlencode "latest=$TS" \
  --data-urlencode "oldest=$TS" \
  --data-urlencode "inclusive=true" \
  --data-urlencode "limit=1" \
  "https://slack.com/api/conversations.history" | jq -c '.messages[0] // {}')"

# Loop guard: skip our own / bot / system (subtype) messages so the bot's own
# Yes/No prompt and confirmation replies never re-trigger analysis.
BOT_ID="$(printf '%s' "$MSG_JSON" | jq -r '.bot_id // ""')"
SUBTYPE="$(printf '%s' "$MSG_JSON" | jq -r '.subtype // ""')"
MSG_USER="$(printf '%s' "$MSG_JSON" | jq -r '.user // ""')"
if [ -n "$BOT_ID" ] || [ -n "$SUBTYPE" ] || [ "$MSG_USER" = "U0AMW73LPBM" ]; then
  echo "skip: bot/system message (bot_id=$BOT_ID subtype=$SUBTYPE user=$MSG_USER)"
  exit 0
fi

MSG_TEXT="$(printf '%s' "$MSG_JSON" | jq -r '.text // ""')"
if [ "$MSG_JSON" = "{}" ] || [ -z "$MSG_TEXT" ]; then
  echo "skip: no message text found for ts=$TS (reply/deleted/empty)"
  exit 0
fi

uuid="$(python3 -c 'import uuid,sys; print(uuid.uuid3(uuid.NAMESPACE_DNS, sys.argv[1]))' "asset-$TS")"

PROMPT="당신은 Biyard #asset 채널의 업무 분류 에이전트입니다.

[메시지 정보]
- channel: $CHANNEL
- thread_ts(ts): $TS
- 메시지 내용:
\"\"\"
$MSG_TEXT
\"\"\"

[해야 할 일]
1. 위 메시지를 분석합니다.
2. 메시지에 링크(URL)가 포함되어 있으면 반드시 Chrome MCP로 각 링크에 접속해서 내용을 확인하고 분석에 반영합니다. (Chrome MCP를 쓸 수 없으면 그 사실을 reason에 적고 텍스트만으로 판단합니다.)
3. 이 메시지가 '업무로 등록해야 하는 것'인지 판단합니다.
   - 업무로 볼 것: 수정/개발/조사/검토 요청, 버그 리포트, 기능 제안, 마감/산출물이 있는 작업 등 실행 가능한(actionable) 항목.
   - 업무가 아님: 단순 인사/잡담/공유성 FYI/감사 표현 등 실행할 행동이 없는 메시지.

[출력 형식 — 매우 중요]
- 분석 설명은 자유롭게 적어도 되지만, 응답의 '맨 마지막 줄'에 아래 형식으로 정확히 한 줄만 출력합니다(다른 텍스트와 같은 줄에 두지 마세요):
  DECISION {\"is_task\": true 또는 false, \"title\": \"한 줄 업무 제목(한국어, 명사형, 간결)\", \"reason\": \"근거 한두 줄(링크 분석 결과 포함)\"}
- title은 Tasks(Asset) 리스트에 들어갈 이름입니다. is_task가 false면 title은 빈 문자열로 둡니다.
- JSON 한 줄은 반드시 유효한 JSON이어야 하며 줄바꿈 없이 한 줄로 출력합니다."

# The session-id is deterministic per message (derived from asset-$TS), so a
# re-trigger reuses it. --session-id only works to CREATE a session; if it
# already exists we must resume it with -r instead.
SESSION_FLAG="$WORKDIR/.claude-session"
if [ -f "$SESSION_FLAG" ]; then
  RAW="$(claude -p "$PROMPT" -r "$uuid" 2>&1)" || true
else
  RAW="$(claude -p "$PROMPT" --session-id "$uuid" 2>&1)" || true
  touch "$SESSION_FLAG"
fi
echo "$RAW"
printf '%s\n' "$RAW"

# Extract the last DECISION {...} line and parse it.
DECISION="$(printf '%s\n' "$RAW" | grep -o 'DECISION[[:space:]]*{.*}' | tail -1 | sed 's/^DECISION[[:space:]]*//')"
if [ -z "$DECISION" ] || ! printf '%s' "$DECISION" | jq -e . >/dev/null 2>&1; then
  echo "warn: no valid DECISION json found — not posting." >&2
  exit 0
fi

IS_TASK="$(printf '%s' "$DECISION" | jq -r '.is_task // false')"
TITLE="$(printf '%s' "$DECISION" | jq -r '.title // ""')"
REASON="$(printf '%s' "$DECISION" | jq -r '.reason // ""')"

if [ "$IS_TASK" = "true" ] && [ -n "$TITLE" ]; then
  echo "decision: task → posting prompt: $TITLE"
  "$REPO/post-asset-task-prompt.sh" "$CHANNEL" "$TS" "$TITLE" "$REASON"
else
  echo "decision: not a task (is_task=$IS_TASK)"
fi

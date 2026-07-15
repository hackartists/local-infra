#!/usr/bin/env bash
# answer-dataroom-mention.sh — #dataroom 에서 @Miner / @hackartist 멘션에
# 스레드로 답변한다. 답변 근거는 asset 프로젝트의 Claude 메모리.
#
# n8n 이 SSH 로 호출한다:
#   answer-dataroom-mention.sh <channel> <ts> [thread_ts]
#
# 설계 (analyze-asset-msg.sh 와 동일한 철학): 셸이 결정적인 일 — 메시지 수집,
# 답변 필터링, 게시 — 을 전부 하고 Claude 는 답변 본문만 쓴다. 게시가 에이전트의
# Slack/셸 툴 권한에 의존하지 않는다.
#
# Claude 는 cwd = asset repo 에서 실행되어 그 프로젝트 메모리를 자연 로드한다.
# 툴은 제거하지 않는다 — CLI 로는 불가능함이 실측됐다:
#   docs/superpowers/specs/2026-07-15-dataroom-mention-qa-design.md
# 따라서 redact_secrets 가 자격증명을 채널 밖으로 내보내지 않는 방어선이다.
set -uo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"

REPO="/Users/hackartist/data/devel/github.com/hackartists/local-infra"
ASSET="/Users/hackartist/data/devel/github.com/biyard/asset"
TOKEN_FILE="${SLACK_CANVAS_TOKEN_FILE:-$HOME/.claude/.slack-canvas-token}"
API="https://slack.com/api"

# shellcheck source=dataroom-qa-lib.sh
source "$REPO/dataroom-qa-lib.sh"

CHANNEL="${1:?usage: answer-dataroom-mention.sh <channel> <ts> [thread_ts]}"
TS="${2:?usage: answer-dataroom-mention.sh <channel> <ts> [thread_ts]}"
THREAD_TS_IN="${3:-}"

TOK="$(tr -d '\n' < "$TOKEN_FILE")"
[ -n "$TOK" ] || { echo "error: empty token in $TOKEN_FILE" >&2; exit 1; }

# 스레드 답글이면 conversations.replies 로, 최상위 메시지면 history 로 가져온다.
# (history 는 스레드 답글을 반환하지 않는다.)
if [ -n "$THREAD_TS_IN" ] && [ "$THREAD_TS_IN" != "$TS" ]; then
  THREAD_TS="$THREAD_TS_IN"
  ALL="$(curl -s -G -H "Authorization: Bearer $TOK" \
    --data-urlencode "channel=$CHANNEL" \
    --data-urlencode "ts=$THREAD_TS" \
    --data-urlencode "limit=200" \
    "$API/conversations.replies")"
  MSG_JSON="$(printf '%s' "$ALL" | jq -c --arg ts "$TS" '[.messages[]? | select(.ts==$ts)][0] // {}')"
  # 질문 이전 메시지 최대 10개를 맥락으로. Slack ts 는 고정폭이라 문자열 비교가 안전하다.
  CONTEXT="$(printf '%s' "$ALL" | jq -r --arg ts "$TS" '
    [.messages[]? | select(.ts < $ts)] | .[-10:] | .[] |
    "<@\(.user // "bot")>: \(.text // "")"')"
else
  THREAD_TS="$TS"
  MSG_JSON="$(curl -s -G -H "Authorization: Bearer $TOK" \
    --data-urlencode "channel=$CHANNEL" \
    --data-urlencode "latest=$TS" \
    --data-urlencode "oldest=$TS" \
    --data-urlencode "inclusive=true" \
    --data-urlencode "limit=1" \
    "$API/conversations.history" | jq -c '.messages[0] // {}')"
  CONTEXT=""
fi

# 루프 가드. 이게 authoritative 하다 (n8n IF 조건은 1차 방어일 뿐).
BOT_ID="$(printf '%s' "$MSG_JSON" | jq -r '.bot_id // ""')"
SUBTYPE="$(printf '%s' "$MSG_JSON" | jq -r '.subtype // ""')"
MSG_USER="$(printf '%s' "$MSG_JSON" | jq -r '.user // ""')"
if SKIP_REASON="$(should_skip "$BOT_ID" "$SUBTYPE" "$MSG_USER")"; then
  echo "skip: $SKIP_REASON"
  exit 0
fi

MSG_TEXT="$(printf '%s' "$MSG_JSON" | jq -r '.text // ""')"
if [ "$MSG_JSON" = "{}" ] || [ -z "$MSG_TEXT" ]; then
  echo "skip: no message text for ts=$TS (deleted/empty)"
  exit 0
fi

# 멘션 재확인 — n8n IF 가 이미 걸렀어야 하지만, 스크립트 단독 실행/오설정 대비.
case "$MSG_TEXT" in
  *"<@$MINER>"*|*"<@$BOT>"*) ;;
  *) echo "skip: no Miner/hackartist mention in ts=$TS"; exit 0 ;;
esac

echo "ok: will answer ts=$TS thread=$THREAD_TS asker=$MSG_USER"
echo "--- text ---"; printf '%s\n' "$MSG_TEXT"
echo "--- context ---"; printf '%s\n' "$CONTEXT"

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

# 스레드마다 결정적 세션 id → 같은 스레드의 후속 질문이 맥락을 유지한다.
uuid="$(python3 -c 'import uuid,sys; print(uuid.uuid3(uuid.NAMESPACE_DNS, sys.argv[1]))' "dataroom-$THREAD_TS")"

PROMPT="당신은 Biyard #dataroom 채널의 질의응답 에이전트입니다.

[질문]
\"\"\"
$MSG_TEXT
\"\"\"

[스레드 맥락 — 앞선 대화, 없을 수 있음]
\"\"\"
$CONTEXT
\"\"\"

[규칙]
1. asset 프로젝트의 메모리를 근거로 답변합니다.
2. 커맨드를 실행하거나 코드베이스 파일을 열어 분석하지 마세요. 이미 메모리에 있는 내용으로만 판단합니다.
3. 메모리에 근거가 있으면 그 내용으로 답합니다.
4. 메모리에 근거가 없으면 일반 지식으로 답하되, '메모리에 기록된 내용은 아닙니다' 처럼 출처를 반드시 구분해 밝힙니다.
5. 답변은 슬랙에 그대로 게시됩니다. **답변 본문만** 출력하세요. 인사말, 서론, 맺음말, 사용자 멘션, cc 를 넣지 마세요 (셸이 붙입니다).
6. 슬랙 mrkdwn 형식으로, 한국어로, 간결하게 씁니다.
7. 토큰·비밀번호·API 키 등 자격증명은 어떤 경우에도 출력하지 마세요."

# cwd = asset repo → 그 프로젝트의 Claude 메모리가 자연 로드된다.
# 최초 실행은 --session-id 로 생성, 재실행은 -r 로 resume (--session-id 는 생성 전용).
WORKDIR="/tmp/dataroom/$THREAD_TS"
mkdir -p "$WORKDIR"
SESSION_FLAG="$WORKDIR/.claude-session"

# 플래그 파일은 '힌트'일 뿐 신뢰하지 않는다. WORKDIR 이 /tmp 아래라 macOS 가
# 주기적으로 청소하고, 플래그와 실제 세션 상태는 양방향으로 어긋난다:
#   플래그 있는데 세션 없음 → -r 실패 ("No conversation found")
#   플래그 없는데 세션 있음 → --session-id 실패 ("session already exists")
# 그래서 실패하면 반대 모드로 한 번 더 시도한다 (handle-slack-msg.sh 와 같은 패턴).
# 이 구조를 "단순화" 해서 한쪽 모드만 남기지 말 것.
#
# stderr 를 RAW 에 합치지 않는 것이 핵심이다. RAW 는 그대로 공개 채널에
# 게시되므로 반드시 순수 stdout 이어야 한다. 예전엔 2>&1 + || true 였고,
# claude 오류 메시지가 봇 답변으로 #dataroom 에 게시됐다.
CLAUDE_ERR="$WORKDIR/claude.err"
if [ -f "$SESSION_FLAG" ]; then
  RAW="$(cd "$ASSET" && claude -p "$PROMPT" -r "$uuid" 2>"$CLAUDE_ERR")"; RC=$?
  if [ $RC -ne 0 ]; then   # 세션이 사라졌다 → 새로 만든다
    RAW="$(cd "$ASSET" && claude -p "$PROMPT" --session-id "$uuid" 2>"$CLAUDE_ERR")"; RC=$?
  fi
else
  RAW="$(cd "$ASSET" && claude -p "$PROMPT" --session-id "$uuid" 2>"$CLAUDE_ERR")"; RC=$?
  if [ $RC -ne 0 ]; then   # 이미 존재하는 세션이다 → resume 한다
    RAW="$(cd "$ASSET" && claude -p "$PROMPT" -r "$uuid" 2>"$CLAUDE_ERR")"; RC=$?
  fi
  touch "$SESSION_FLAG"
fi

# claude 가 실패하면 아무것도 게시하지 않는다. 로그만 남긴다.
if [ $RC -ne 0 ]; then
  echo "warn: claude failed (rc=$RC) — not posting. stderr:" >&2
  cat "$CLAUDE_ERR" >&2
  exit 0
fi

# 게시 전 마지막 방어선. 두 단계는 관심사가 다르다:
#   redact_secrets            — 자격증명이 채널로 나가는 것을 막는다
#   neutralize_slack_controls — 주입된 답변이 채널 전체를 핑하거나
#                               피싱 링크를 심는 것을 막는다
# 순서 주의: 중립화를 먼저 하면 자격증명 판정이 흐려진다. redact 먼저.
REDACTED="$(printf '%s' "$RAW" | redact_secrets)"
if [ "$REDACTED" != "$RAW" ]; then
  echo "warn: redacted credential-shaped content from answer (ts=$TS)" >&2
fi
ANSWER="$(printf '%s' "$REDACTED" | neutralize_slack_controls)"

if [ -z "${ANSWER//[[:space:]]/}" ]; then
  echo "warn: empty answer — not posting" >&2
  exit 0
fi

TEXT="$(format_reply "$MSG_USER" "$ANSWER")"

# 한글 payload 는 반드시 jq -n --arg 로 빌드한다 (셸 인라인 시 인코딩 에러).
PAYLOAD="$(jq -n \
  --arg channel "$CHANNEL" \
  --arg thread_ts "$THREAD_TS" \
  --arg text "$TEXT" \
  '{channel:$channel, thread_ts:$thread_ts, text:$text}')"

RESP="$(printf '%s' "$PAYLOAD" | curl -s -X POST \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @- "$API/chat.postMessage")"

if [ "$(printf '%s' "$RESP" | jq -r '.ok')" != "true" ]; then
  printf '%s' "$RESP" | jq '{ok, error}' >&2
  exit 1
fi
echo "posted: $(printf '%s' "$RESP" | jq -r '.ts')"

#!/usr/bin/env bash
# dataroom-qa-lib.sh — answer-dataroom-mention.sh 의 순수 헬퍼.
# I/O 를 하지 않는다. 메인 스크립트와 테스트가 각각 source 한다.
#
# 이 파일이 순수한 이유: redact_secrets 는 자격증명이 공개 슬랙 채널로
# 나가는 것을 막는 유일한 방어선이므로 반드시 단위 테스트가 가능해야 한다.

MINER="U03QHDMCVB2"        # 사람
BOT="U0AMW73LPBM"          # hackartist — 이 봇 자신

# redact_secrets — stdin 에서 자격증명 모양의 문자열을 [REDACTED] 로 치환.
#
# dataroom 메시지는 신뢰할 수 없는 입력이고(누구나 작성 가능), 그것이 곧
# 에이전트의 프롬프트이며, 답변은 공개 채널에 게시된다. 에이전트의 툴은
# 제거할 수 없으므로 이 필터가 마지막 방어선이다.
redact_secrets() {
  sed -E \
    -e 's/xox[baprse]-[A-Za-z0-9-]+/[REDACTED]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
    -e 's/(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]+/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED]/g'
}

# should_skip — 이 메시지에 답변하면 안 되는지 판정.
# Args: <bot_id> <subtype> <user>
# 스킵해야 하면 사유를 출력하고 0 을 반환, 아니면 1 을 반환.
#
# 자기 루프 차단: 우리 답변은 "cc. <@Miner>" 로 끝나므로 트리거 조건을
# 스스로 만족한다. 이 가드가 authoritative 하다 (n8n IF 조건은 1차 방어일 뿐).
should_skip() {
  local bot_id="$1" subtype="$2" user="$3"
  if [ -n "$bot_id" ]; then echo "bot message (bot_id=$bot_id)"; return 0; fi
  if [ -n "$subtype" ]; then echo "system message (subtype=$subtype)"; return 0; fi
  if [ "$user" = "$BOT" ]; then echo "self message (user=$user)"; return 0; fi
  return 1
}

# format_reply — 게시할 슬랙 메시지 본문 생성.
# Args: <asker_user_id> <answer>
# 질문자를 멘션하고, 마지막 줄에 Miner 를 cc 한다.
format_reply() {
  local asker="$1" answer="$2"
  printf '<@%s> %s\n\ncc. <@%s>' "$asker" "$answer" "$MINER"
}

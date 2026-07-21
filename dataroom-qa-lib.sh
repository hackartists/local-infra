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
#
# 파이프라인 3단:
#   1) perl : zero-width 문자 제거. 토큰 중간에 U+200B 를 끼워 넣으면 패턴이
#             깨져 앞부분만 마스킹되고 나머지가 유출된다. 매칭 전에 반드시 제거.
#   2) awk  : PEM 개인키를 BEGIN..END 블록 통째로 제거. 헤더 줄만 치환하면
#             키 본문과 END 줄이 그대로 나간다 (겉보기엔 처리된 것처럼 보여서
#             가장 위험한 실패 모드였다). BSD sed 의 범위 c\ 는 신뢰할 수 없어 awk 사용.
#   3) sed  : 접두사가 뚜렷한 토큰들을 치환.
#
# 알려진 한계 (의도적으로 처리하지 않음):
#   - 진짜 개행으로 쪼개진 토큰: 줄 단위 도구로는 일반적으로 막을 수 없다.
#   - base64/hex 인코딩되거나 산문으로 설명된 비밀("xoxb-358137 로 시작해"),
#     문자 사이에 공백을 넣은 형태: 패턴 필터의 범위 밖 (의미 탐지가 필요).
#   - 접두사 없는 AWS secret access key(40자), PASSWORD=hunter2 류: 고유한
#     모양이 없어 포괄 패턴을 쓰면 오탐이 감당 불가능해진다.
#   - 산문 속 AKIA+16자가 마스킹되는 것은 무해한 오탐으로 허용한다.
#   - END 없는 BEGIN 줄은 이후 입력을 전부 삼킨다. 유출보다 누락이 안전하므로
#     의도한 fail-safe 방향이다.
redact_secrets() {
  perl -CSD -pe 's/[\x{200B}-\x{200D}\x{FEFF}]//g' \
  | awk '
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/ {
        if (!inkey) print "[REDACTED]"
        # 같은 줄에서 END 까지 끝났으면 블록 모드로 들어가지 않는다.
        # (안 그러면 정상 종료된 한 줄짜리 키가 답변 뒷부분을 통째로 삼킨다)
        inkey = /-----END [A-Z ]*PRIVATE KEY-----/ ? 0 : 1
        next
      }
      inkey && /-----END [A-Z ]*PRIVATE KEY-----/ { inkey=0; next }
      inkey { next }
      { print }' \
  | sed -E \
    -e 's/xox[a-z]-[A-Za-z0-9-]+/[REDACTED]/g' \
    -e 's/xapp-[A-Za-z0-9-]+/[REDACTED]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
    -e 's/(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]+/[REDACTED]/g' \
    -e 's/(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/[REDACTED]/g'
}

# neutralize_slack_controls — stdin 의 슬랙 제어 시퀀스를 무해한 텍스트로.
#
# redact_secrets 와 관심사가 다르다: 저쪽은 자격증명 유출, 이쪽은 채널 남용.
# 답변 텍스트는 신뢰할 수 없는 공개 입력을 프롬프트로 받은 LLM 이 만들었고
# 공개 채널에 그대로 게시된다. 프롬프트 인젝션된 답변이 워크스페이스 전체를
# 멘션하거나 피싱 링크를 심는 것을 막는다.
#
# 주의: 답변 본문에만 적용한다. format_reply 가 나중에 붙이는 질문자 멘션과
# cc. <@MINER> 는 의도된 진짜 멘션이므로 반드시 핑되어야 한다.
neutralize_slack_controls() {
  sed -E \
    -e 's#<(https?://[^>|]*)\|[^>]*>#\1#g' \
    -e 's/<!([^>|]*)(\|[^>]*)?>/@\1/g' \
    -e 's/<@([A-Za-z0-9]+)(\|[^>]*)?>/@\1/g'
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

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

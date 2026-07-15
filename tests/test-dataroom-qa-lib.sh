#!/usr/bin/env bash
# tests/test-dataroom-qa-lib.sh — dataroom-qa-lib.sh 의 순수 함수 테스트.
# 프레임워크 없음. 실행: ./tests/test-dataroom-qa-lib.sh
set -uo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
cd "$(dirname "$0")/.."
source ./dataroom-qa-lib.sh

PASS=0; FAIL=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"
  fi
}

# --- redact_secrets ---
check "slack bot token 마스킹" \
  "토큰은 [REDACTED] 입니다" \
  "$(printf '%s' '토큰은 xoxb-FAKE000000001-FAKE0000000002-AbCdEfGhIjKlMnOp 입니다' | redact_secrets)"

check "slack user token 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'xoxp-1234567890-abcdef' | redact_secrets)"

check "anthropic key 마스킹" \
  "key=[REDACTED]" \
  "$(printf '%s' 'key=sk-ant-api03-AbCdEf_Gh-Ij' | redact_secrets)"

check "github token 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'ghp_AbCdEf123456' | redact_secrets)"

check "AWS access key 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'AKIAIOSFODNN7EXAMPLE' | redact_secrets)"

check "private key 헤더 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' '-----BEGIN RSA PRIVATE KEY-----' | redact_secrets)"

check "평범한 한국어는 그대로" \
  "데이터룸은 실사 자료를 모아두는 공간입니다" \
  "$(printf '%s' '데이터룸은 실사 자료를 모아두는 공간입니다' | redact_secrets)"

check "코드블록/일반 텍스트는 그대로" \
  "workspace id 로 스코프합니다" \
  "$(printf '%s' 'workspace id 로 스코프합니다' | redact_secrets)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

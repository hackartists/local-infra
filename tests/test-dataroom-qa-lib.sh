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

check "PEM 블록 전체(본문+END 포함) 마스킹" \
  "[REDACTED]" \
  "$(printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----' 'MIIEowIBAAKCAQEA1234567890abcdef' 'ZZZZfakekeybodyline2' '-----END RSA PRIVATE KEY-----' | redact_secrets)"

check "PEM 블록 앞뒤 텍스트는 유지" \
  "$(printf '앞 문장\n[REDACTED]\n뒤 문장')" \
  "$(printf '%s\n' '앞 문장' '-----BEGIN OPENSSH PRIVATE KEY-----' 'b3BlbnNzaC1rZXktdjEAAAAA' '-----END OPENSSH PRIVATE KEY-----' '뒤 문장' | redact_secrets)"

check "한 줄에 끝나는 PEM 은 그 줄만 먹고 뒷부분은 유지" \
  "$(printf '[REDACTED]\n뒤 문장')" \
  "$(printf '%s\n' '-----BEGIN RSA PRIVATE KEY----- MIIEsecret -----END RSA PRIVATE KEY-----' '뒤 문장' | redact_secrets)"

check "xapp- (Socket Mode) 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'xapp-1-A012345-678-abcdef' | redact_secrets)"

check "xoxc- (client) 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'xoxc-1234567890-abcdef' | redact_secrets)"

check "AWS STS 임시 키(ASIA) 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'ASIAIOSFODNN7EXAMPLE' | redact_secrets)"

check "zero-width 로 쪼갠 토큰도 마스킹" \
  "[REDACTED]" \
  "$(printf 'xoxb-3581374334913\xe2\x80\x8b-10744241703395-AbCdEf' | redact_secrets)"

check "JWT 마스킹" \
  "[REDACTED]" \
  "$(printf '%s' 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r' | redact_secrets)"

# --- should_skip ---
# 반환값 0 = 스킵해야 함
skip_reason() { should_skip "$1" "$2" "$3"; }
skip_code()   { should_skip "$1" "$2" "$3" >/dev/null; echo $?; }

check "bot_id 있으면 스킵" "0" "$(skip_code "B0AN66CRD2Q" "" "U03QHDMCVB2")"
check "bot_id 스킵 사유" "bot message (bot_id=B0AN66CRD2Q)" "$(skip_reason "B0AN66CRD2Q" "" "U03QHDMCVB2")"
check "subtype 있으면 스킵" "0" "$(skip_code "" "channel_join" "U03QHDMCVB2")"
check "봇 자신이면 스킵" "0" "$(skip_code "" "" "U0AMW73LPBM")"
check "봇 자신 스킵 사유" "self message (user=U0AMW73LPBM)" "$(skip_reason "" "" "U0AMW73LPBM")"
check "사람의 일반 메시지는 스킵 안 함" "1" "$(skip_code "" "" "U03QHDMCVB2")"

# --- format_reply ---
check "질문자 멘션 + cc Miner" \
  "$(printf '<@U0123ABC> 데이터룸은 실사 자료 공간입니다.\n\ncc. <@U03QHDMCVB2>')" \
  "$(format_reply "U0123ABC" "데이터룸은 실사 자료 공간입니다.")"

check "여러 줄 답변도 cc 는 맨 끝" \
  "$(printf '<@U0123ABC> 첫째 줄\n둘째 줄\n\ncc. <@U03QHDMCVB2>')" \
  "$(format_reply "U0123ABC" "$(printf '첫째 줄\n둘째 줄')")"

# --- neutralize_slack_controls ---
check "<!channel> 은 핑 안 되는 텍스트로" \
  "@channel 공지입니다" \
  "$(printf '%s' '<!channel> 공지입니다' | neutralize_slack_controls)"

check "<!here> 은 핑 안 되는 텍스트로" \
  "@here" \
  "$(printf '%s' '<!here>' | neutralize_slack_controls)"

check "<!everyone> 은 핑 안 되는 텍스트로" \
  "@everyone" \
  "$(printf '%s' '<!everyone>' | neutralize_slack_controls)"

check "사용자 멘션은 핑 안 되는 텍스트로" \
  "@U0123ABC 님께" \
  "$(printf '%s' '<@U0123ABC> 님께' | neutralize_slack_controls)"

check "표시이름 붙은 사용자 멘션도 무력화" \
  "@U0123ABC" \
  "$(printf '%s' '<@U0123ABC|hackartist>' | neutralize_slack_controls)"

check "user group 멘션도 무력화" \
  "@subteam^S0123ABC" \
  "$(printf '%s' '<!subteam^S0123ABC|@everyone-group>' | neutralize_slack_controls)"

check "마스킹된 링크는 실제 목적지 노출" \
  "https://evil.example.com" \
  "$(printf '%s' '<https://evil.example.com|공식 문서>' | neutralize_slack_controls)"

check "일반 산문/평문 URL/슬랙 ID 는 그대로" \
  "데이터룸 문서는 https://docs.example.com 참고. 채널 C09PY44SDHD, 담당자 U03QHDMCVB2" \
  "$(printf '%s' '데이터룸 문서는 https://docs.example.com 참고. 채널 C09PY44SDHD, 담당자 U03QHDMCVB2' | neutralize_slack_controls)"

check "코드/부등호는 그대로" \
  "if (a < b || c > d) { return a; }" \
  "$(printf '%s' 'if (a < b || c > d) { return a; }' | neutralize_slack_controls)"

# neutralize 는 답변에만 적용된다. format_reply 가 나중에 붙이는 진짜 멘션은
# 그대로 핑되어야 한다 — 이 합성이 실제 호출 순서다.
check "neutralize 후에도 format_reply 의 실제 멘션은 살아있음" \
  "$(printf '<@U0123ABC> @channel 관련 안내\n\ncc. <@U03QHDMCVB2>')" \
  "$(format_reply "U0123ABC" "$(printf '%s' '<!channel> 관련 안내' | neutralize_slack_controls)")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

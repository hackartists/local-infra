# #asset 채널 업무 분류 워크플로우

`#asset` 채널에 올라온 메시지를 Claude로 분석해 "업무로 등록할지" 판단하고,
업무면 스레드에 Yes/No 확인 메시지를 띄운 뒤 Yes 시 Slack **Tasks(Asset)** 리스트에 등록한다.

## 흐름

```
#asset 메시지
  └─[n8n] Slack Workflow (Uuy2lbpg5w8BzlqI)
        Slack Trigger(message) → Switch case2 "Asset Message"(type=message & channel=C09PY44SDHD)
        → SSH: analyze-asset-msg.sh <channel> <ts> <thread_ts>
              · 봇/시스템/스레드답글/빈 메시지는 스킵 (무한루프 방지)
              · claude -p 로 분석 (링크는 Chrome MCP로 접속·분석)
              · claude는 마지막 줄에  DECISION {"is_task",...,"title","reason"}  출력
              · 셸이 파싱 → 업무면 post-asset-task-prompt.sh 호출
        → post-asset-task-prompt.sh: 스레드에 [업무 내용 + cc @Miner + Yes/No 버튼] 게시
                                      버튼 value = {channel, thread_ts, task}

[사용자가 Yes/No 클릭]
  └─ Slack Interactivity → https://n8n.hackartist.io/webhook/asset-task-action
        └─[n8n] Asset Task Interactivity (qBMUAJ2TTE6XeMZq)
              Webhook(POST, 즉시 200) → Code(payload 파싱) → SSH: asset-task-action.sh
                  · Yes → add-asset-task.sh: slack-tasks.sh add 기획 "<task>" + 스레드에 "✅ 등록" 답글
                  · No  → 버튼 메시지를 "❎ 등록 안 함"으로 교체
                  · 두 경우 모두 response_url 로 원본 버튼 비활성화
```

## 스크립트 (repo root, macOS 호스트에서 SSH 실행)

| 스크립트 | 역할 |
|---|---|
| `analyze-asset-msg.sh <channel> <ts> [thread_ts]` | 메시지 분석(claude+Chrome) → 업무면 프롬프트 게시 |
| `post-asset-task-prompt.sh <channel> <thread_ts> <task> [reason]` | 스레드에 Yes/No Block Kit 게시 |
| `asset-task-action.sh <action_id> <channel> <thread_ts> <task_b64> [response_url]` | 버튼 클릭 처리 (Yes=등록, No=취소) |
| `add-asset-task.sh <channel> <thread_ts> <task>` | Tasks(Asset) 등록 + 스레드 확인 답글 |

- 봇 토큰: `~/.claude/.slack-canvas-token` (스코프 `chat:write`, `lists:write` 등 확인됨).
- Tasks(Asset) 등록: `slack-tasks` 스킬의 `slack-tasks.sh add 기획 "<이름>"` (구분=기획).
- 상수: `#asset = C09PY44SDHD`, Miner = `U03QHDMCVB2`, bot user = `U0AMW73LPBM`.

## 수동 설정 (테스트 전 1회)

1. **Slack 앱 — Interactivity & Shortcuts** 활성화 후
   **Request URL = `https://n8n.hackartist.io/webhook/asset-task-action`** 저장.
2. **Slack 앱 — Event Subscriptions** 에서 봇 이벤트로 **`message.channels`** 구독 추가
   (기존 `reaction_added`, `app_mention` 에 더해). Request URL 은 기존 Slack Trigger 것 유지.
3. 봇이 **#asset 채널의 멤버**인지 확인 (`/invite @<bot>`).

## 테스트

1. #asset 에 업무성 메시지(예: "랜딩 페이지 로딩 느림, https://example.com 확인 필요") 작성.
2. 스레드에 `업무 내용 + cc @Miner + Yes/No` 가 달리는지 확인.
3. **Yes** → Tasks(Asset) 리스트에 항목 추가 + 스레드에 "✅ 등록" 답글, 버튼 비활성화.
4. 잡담성 메시지는 아무 반응 없어야 함(봇/스레드답글 재트리거 없음).

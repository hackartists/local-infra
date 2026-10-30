#!/bin/zsh
source /Users/hackartist/.zshrc

# Summarizes one Google Meet "Notes by Gemini" doc for Slack.
# Called by the n8n workflow "Send Meet notes summary to Slack": n8n exports the
# doc as text/plain, uploads it over SFTP to $NOTES_DIR/<file-id>.txt, then runs
#   ./summarize-meeting.sh <file-id> '<doc title>' '<doc url>'
# stdout is posted to Slack verbatim, so ONLY the final message goes to stdout;
# every diagnostic goes to stderr. Non-zero exit = n8n posts a failure notice.
# stdout exactly "SKIP" with exit 0 = empty/false-start doc, n8n posts nothing.

FILE_ID=$1
DOC_TITLE=$2
DOC_URL=$3

if [[ -z "$FILE_ID" || -z "$DOC_TITLE" ]]; then
  echo "usage: $0 <drive-file-id> <doc-title> [doc-url]" >&2
  exit 2
fi
# The id becomes a path component; reject anything that is not a Drive id so a
# crafted value cannot point the script (or its cleanup) at another file.
if [[ ! "$FILE_ID" =~ '^[A-Za-z0-9_-]+$' ]]; then
  echo "invalid Drive file id: $FILE_ID" >&2
  exit 2
fi
[[ -z "$DOC_URL" ]] && DOC_URL="https://docs.google.com/document/d/$FILE_ID/edit"

SCRIPT_DIR="${0:A:h}"
# Outside the repo on purpose: meeting notes are sensitive and must never be
# picked up by git. n8n uploads into this directory, so it has to exist before
# the upload step runs (created once by hand; mkdir here keeps it self-healing).
NOTES_DIR="${MEET_NOTES_DIR:-$HOME/.cache/n8n-meet-notes}"
NOTES_FILE="$NOTES_DIR/$FILE_ID.txt"
mkdir -p "$NOTES_DIR" || exit 1

# `rm` is aliased to a trash-mover in .zshrc; `command rm` really deletes.
cleanup() {
  local ec=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$SUMMARIZER_PID" ]] && kill -0 "$SUMMARIZER_PID" 2>/dev/null; then
    pkill -TERM -P "$SUMMARIZER_PID" 2>/dev/null
    kill -TERM "$SUMMARIZER_PID" 2>/dev/null
    sleep 1
    pkill -KILL -P "$SUMMARIZER_PID" 2>/dev/null
    kill -KILL "$SUMMARIZER_PID" 2>/dev/null
  fi
  if [[ -n "$WATCHDOG_PID" ]]; then
    pkill -P "$WATCHDOG_PID" 2>/dev/null
    kill "$WATCHDOG_PID" 2>/dev/null
  fi
  [[ -n "$OUT_FILE" ]] && command rm -f "$OUT_FILE"
  # The notes copy is deleted on every exit path, success or failure.
  [[ -f "$NOTES_FILE" ]] && command rm -f "$NOTES_FILE"
  exit $ec
}
trap cleanup EXIT INT TERM HUP

if [[ ! -r "$NOTES_FILE" ]]; then
  echo "Notes file not found: $NOTES_FILE (did the n8n upload step run?)" >&2
  exit 2
fi
# Gemini creates the doc before it finishes writing it. An (almost) empty doc
# must fail loudly rather than produce a hollow summary that dedupe then buries.
MIN_CHARS="${MIN_CHARS:-200}"
NOTES_CHARS=$(wc -m < "$NOTES_FILE" | tr -d ' ')
if (( NOTES_CHARS < MIN_CHARS )); then
  echo "Notes doc has only $NOTES_CHARS characters; Gemini has probably not finished writing it." >&2
  exit 6
fi
# A "false start" (someone opened the Meet link for a few seconds) still gets
# its own notes doc: boilerplate only, no one speaking in the transcript tab.
# Skip it quietly: stdout is exactly SKIP and the exit code is 0, so n8n posts
# neither a summary nor a failure notice. Speaker lines look like
# "Ryan Cho：발언" (FULLWIDTH COLON) and are counted after the transcript header;
# a doc without a transcript tab is not judged by this check.
MIN_SPEAKER_LINES="${MIN_SPEAKER_LINES:-5}"
SPEAKER_LINES=$(perl -Mutf8 -CSD -ne '
  $t = 1 if / - (?:스크립트|Transcript)\r?$/;
  $n++ if $t && /^[^：\n]{1,40}：/;
  END { print $t ? $n + 0 : -1 }' < "$NOTES_FILE")
if (( SPEAKER_LINES >= 0 && SPEAKER_LINES < MIN_SPEAKER_LINES )); then
  echo "Skipping: transcript has $SPEAKER_LINES speaker lines (< $MIN_SPEAKER_LINES); probably a false start." >&2
  print -r -- "SKIP"
  exit 0
fi

# Title shape: "<meeting> - YYYY/MM/DD HH:MM KST - Notes by Gemini" (or the
# Korean "- Gemini가 작성한 회의록"). Split it here, deterministically, so the
# header never depends on the model.
MEETING="$DOC_TITLE"
MEETING="${MEETING% - Notes by Gemini}"
MEETING="${MEETING% - Gemini가 작성한 회의록}"
WHEN=""
if [[ "$MEETING" =~ '^(.*) - ([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}( [A-Z]{2,5})?)$' ]]; then
  MEETING="${match[1]}"
  WHEN="${match[2]}"
fi
# Slack mrkdwn control characters in a title would break the header/link.
slack_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  print -r -- "$s"
}
MEETING_ESC="$(slack_escape "$MEETING")"

# Long-lived token (see review-pr.sh): the interactive login expires and would
# strand an unattended workflow. `claude setup-token` writes one.
TOKEN_FILE="${CLAUDE_TOKEN_FILE:-$HOME/.claude/review-pr-token}"
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" && -r "$TOKEN_FILE" ]]; then
  CLAUDE_CODE_OAUTH_TOKEN="${$(<"$TOKEN_FILE")//[[:space:]]/}"
fi
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
  echo "No Claude token: set CLAUDE_CODE_OAUTH_TOKEN or write one to $TOKEN_FILE" >&2
  echo "Generate it with: claude setup-token" >&2
  exit 3
fi
export CLAUDE_CODE_OAUTH_TOKEN

SUMMARY_MODEL="${SUMMARY_MODEL:-sonnet}"
TIMEOUT_SECONDS="${SUMMARY_TIMEOUT_SECONDS:-600}"

PROMPT="The text on stdin is a Google Meet meeting-notes document generated by Gemini (meeting: \"$MEETING\"). Write the body of a Slack message, in Korean, that summarizes it for teammates who missed the meeting.

Output rules (strict):
- Output ONLY the message body. No preamble, no closing remarks, no code fences, no title line (a header is added separately).
- Slack mrkdwn only: *bold* with single asterisks, bullets with \"• \". No Markdown headings (#), no tables, no **double asterisks**, no [text](url) links.
- Use exactly these sections, in this order:
*요약*
3~5줄의 핵심 요약 (각 줄은 \"• \"로 시작)

*결정 사항*
• 결정된 내용 (없으면 \"• 없음\")

*할 일*
• 담당자 — 할 일 (기한) — 담당자/기한이 문서에 있을 때만 적고, 없으면 생략. 할 일이 없으면 \"• 없음\"
- Keep names, product names, numbers and dates exactly as written in the notes. Do not invent owners, deadlines or decisions.
- Keep it under 1500 characters."

OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/summarize-meeting.XXXXXX")" || exit 1

# Neutral working dir: summarizing needs no repository, tools or workspace trust.
cd "$NOTES_DIR" || exit 1

# Background + wait so INT/TERM traps fire while claude runs (see review-pr.sh).
# No tools, no MCP servers, no saved session: this is a pure text transform.
claude --model "$SUMMARY_MODEL" -p "$PROMPT" \
  --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence \
  < "$NOTES_FILE" > "$OUT_FILE" &
SUMMARIZER_PID=$!
# Hard timeout: the n8n SSH node has none, so a hung claude would hang the run.
# Its stdio is detached and its sleep is killed with it: a leftover sleep that
# still holds the SSH channel's stdout keeps the n8n node waiting until it ends.
( sleep "$TIMEOUT_SECONDS" && kill -TERM "$SUMMARIZER_PID" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
WATCHDOG_PID=$!
wait "$SUMMARIZER_PID"
SUMMARY_EC=$?
SUMMARIZER_PID=
pkill -P "$WATCHDOG_PID" 2>/dev/null
kill "$WATCHDOG_PID" 2>/dev/null
WATCHDOG_PID=

if (( SUMMARY_EC != 0 )); then
  echo "claude exited with $SUMMARY_EC (timeout ${TIMEOUT_SECONDS}s)" >&2
  exit 4
fi
BODY="$(<"$OUT_FILE")"
# Strip stray code fences the model may add despite the instructions.
BODY="$(print -r -- "$BODY" | sed -e '/^```/d')"
if [[ -z "${BODY//[[:space:]]/}" ]]; then
  echo "claude returned an empty summary" >&2
  exit 5
fi

HEADER=":memo: *회의록 요약 — $MEETING_ESC*"
[[ -n "$WHEN" ]] && HEADER+=" ($WHEN)"
print -r -- "$HEADER"
print -r -- ""
print -r -- "$BODY"
print -r -- ""
print -r -- "<$DOC_URL|원문 보기 (Notes by Gemini)>"

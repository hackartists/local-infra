#!/bin/zsh
source /Users/hackartist/.zshrc

PR_NUMBER=$1
PR_URL=$2

# The URL is optional: callers that only know the PR number (n8n passing
# {{ $json.body.number }}) get it built against DEFAULT_REPO. Pass the real URL
# whenever you have it — it is what makes this script work for other repos.
DEFAULT_REPO="${DEFAULT_REPO:-biyard/dataroom}"

if [[ -z "$PR_NUMBER" ]]; then
  echo "usage: $0 <pr-number> [pr-url]" >&2
  exit 2
fi
if [[ "$PR_NUMBER" != <-> ]]; then
  echo "PR number must be numeric, got: $PR_NUMBER" >&2
  exit 2
fi
if [[ -z "$PR_URL" ]]; then
  PR_URL="https://github.com/$DEFAULT_REPO/pull/$PR_NUMBER"
  echo "No PR URL given; defaulting to $PR_URL"
fi

# Anchor the work dir to this script's location, not $PWD — n8n invokes this
# with an arbitrary working directory. /github/ is already gitignored.
SCRIPT_DIR="${0:A:h}"

# Base repository comes from the PR URL, not from any git remote: the PR head
# may live in a fork, and the review must be posted against the base repo.
BASE_REPO="${${PR_URL#*github.com/}%%/pull/*}"
if [[ -z "$BASE_REPO" || "$BASE_REPO" == "$PR_URL" ]]; then
  echo "could not parse owner/repo from PR_URL: $PR_URL" >&2
  exit 2
fi

# Review rules come from the shared context repository, the same files the
# development sessions for that repo use: CLAUDE.md holds the project rules and
# CODE_REVIEW.md how to review against them. Keeping them there means a rule
# changes in one place for both writing and reviewing code. Loaded before
# cloning so a missing guide fails fast instead of after a monorepo fetch.
CONTEXTS_ROOT="${CONTEXTS_ROOT:-$HOME/data/devel/github.com/hackartists/contexts}"
CONTEXT_DIR="$CONTEXTS_ROOT/${BASE_REPO##*/}"
REVIEW_GUIDE_FILE="$CONTEXT_DIR/CODE_REVIEW.md"
PROJECT_RULES_FILE="$CONTEXT_DIR/CLAUDE.md"
# No pull here: the contexts watchdog (launchd) keeps the clone in sync, and a
# second git process in the same repo would race it for index.lock.
for f in "$REVIEW_GUIDE_FILE" "$PROJECT_RULES_FILE"; do
  if [[ ! -r "$f" ]]; then
    echo "Review context not found: $f" >&2
    exit 2
  fi
done
REVIEW_GUIDE="$(<"$REVIEW_GUIDE_FILE")"
PROJECT_RULES="$(<"$PROJECT_RULES_FILE")"
# CLAUDE.md sends readers to sibling files (SCS.md, MOBILE.md, ...). The
# reviewer cannot open them from the PR checkout, so every other .md in the
# context dir rides along, each tagged with its name so the references resolve.
CONTEXT_FILES=""
for f in "$CONTEXT_DIR"/*.md(N); do
  [[ "$f" == "$REVIEW_GUIDE_FILE" || "$f" == "$PROJECT_RULES_FILE" ]] && continue
  CONTEXT_FILES+="<context-file name=\"${f:t}\">
$(<"$f")
</context-file>

"
done

# One workspace per repository, not per PR. Claude records workspace trust by
# directory and never inherits it, so a per-PR path would need a fresh approval
# on every run; a stable path is approved once, by hand. The cost is that two
# reviews of the same repo must not share it, hence the lock below.
CLONE_DIR="$SCRIPT_DIR/github/${BASE_REPO##*/}"
LOCK_DIR="$CLONE_DIR.lock"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-900}"

# `rm` is aliased to a trash-mover in .zshrc, which fails silently on paths it
# cannot move. `command rm` bypasses the alias so cleanup actually happens.
cleanup() {
  local ec=$?
  trap - EXIT INT TERM HUP
  # Kill the reviewer first. Without this the clone stays locked open by a
  # hung reviewer, and a `kill` aimed at this script would otherwise wait for
  # that child to finish before the trap could run at all.
  if [[ -n "$REVIEWER_PID" ]] && kill -0 "$REVIEWER_PID" 2>/dev/null; then
    pkill -TERM -P "$REVIEWER_PID" 2>/dev/null
    kill -TERM "$REVIEWER_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$REVIEWER_PID" 2>/dev/null || break
      sleep 1
    done
    pkill -KILL -P "$REVIEWER_PID" 2>/dev/null
    kill -KILL "$REVIEWER_PID" 2>/dev/null
  fi
  # The workspace itself survives: it is the directory the user approved once,
  # and re-cloning a monorepo per review is wasted bandwidth. Only the lock is
  # released, so the next run can take it.
  if [[ -n "$LOCK_HELD" && -d "$LOCK_DIR" ]]; then
    command rm -rf "$LOCK_DIR"
  fi
  exit $ec
}
# EXIT covers normal and error exits; the signal traps cover kill/hangup/Ctrl-C.
# SIGKILL (kill -9) and host power loss cannot be trapped — the stale-lock
# recovery below is what unblocks the workspace in those cases.
trap cleanup EXIT INT TERM HUP

# mkdir is atomic, which is what makes it usable as a lock; macOS ships no
# flock(1). A lock whose owning process is gone is stale and gets reclaimed.
mkdir -p "$SCRIPT_DIR/github" || exit 1
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  owner=""
  [[ -r "$LOCK_DIR/pid" ]] && owner="$(<"$LOCK_DIR/pid")"
  if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
    echo "Reclaiming stale lock from PID ${owner:-unknown}"
    command rm -rf "$LOCK_DIR"
    continue
  fi
  if (( waited >= LOCK_WAIT_SECONDS )); then
    echo "Timed out after ${LOCK_WAIT_SECONDS}s waiting for $BASE_REPO workspace (held by PID $owner)" >&2
    exit 4
  fi
  echo "Workspace busy (PID $owner); waiting..."
  sleep 10
  (( waited += 10 ))
done
LOCK_HELD=1
echo $$ > "$LOCK_DIR/pid"

# Clone once, then reuse. pull/N/head resolves whether or not the PR comes from
# a fork, and keeping origin on the base repo is what makes `gh pr diff` and the
# review POST target the right place. Detached HEAD avoids accumulating one
# local branch per PR reviewed.
if [[ -d "$CLONE_DIR/.git" ]]; then
  echo "Reusing workspace $CLONE_DIR"
  cd "$CLONE_DIR" || exit 1
  command git remote set-url origin "git@github.com:$BASE_REPO.git" 2>/dev/null
else
  echo "Cloning $BASE_REPO into $CLONE_DIR"
  command rm -rf "$CLONE_DIR"
  command git clone --depth 1 --quiet "git@github.com:$BASE_REPO.git" "$CLONE_DIR" || exit 1
  cd "$CLONE_DIR" || exit 1
fi

echo "Fetching PR #$PR_NUMBER"
command git fetch --depth 1 --force --quiet origin "pull/$PR_NUMBER/head" || exit 1
command git checkout --quiet --detach FETCH_HEAD || exit 1
command git reset --hard --quiet FETCH_HEAD || exit 1
command git clean -qfd || exit 1

echo "Reviewing PR $PR_NUMBER from $PR_URL in $CLONE_DIR"

# An untrusted workspace does not block the run — it silently discards the
# repo's own .claude/settings.json permission grants, so the reviewer loses the
# tools it needs and produces nothing. Fail loudly instead. Approval is a
# one-time manual step per repository, which is why the workspace path is
# stable rather than per-PR.
if ! python3 -c "
import json, sys
config = json.load(open('$HOME/.claude.json'))
entry = config.get('projects', {}).get('$CLONE_DIR', {})
sys.exit(0 if entry.get('hasTrustDialogAccepted') else 1)
" 2>/dev/null; then
  echo "Workspace $CLONE_DIR is not trusted; the repo's permission grants would be ignored." >&2
  echo "Approve it once: run 'claude' interactively in that directory and accept the trust prompt." >&2
  exit 5
fi

# Model is overridable so n8n can swap it per call without editing this file.
REVIEW_MODEL="${REVIEW_MODEL:-sonnet}"

# Authenticate with a long-lived token rather than the interactive login in
# ~/.claude/.credentials.json: that session expires and would strand the webhook
# with no one to re-run `claude /login`. Generate the token with
# `claude setup-token` (needs a browser once) and store it in TOKEN_FILE, or
# export CLAUDE_CODE_OAUTH_TOKEN. The token draws on the Claude subscription,
# not pay-per-token API billing.
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

REVIEW_PROMPT="Review the pull request $PR_URL (PR number $PR_NUMBER, base repository $BASE_REPO). This working directory is a checkout of the PR head.

Review against the project rules and follow the review guide below. Wherever they say <PR number>, use $PR_NUMBER. The project rules and the context files they refer to are the shared development context for this repository; they are not files in this checkout.

<project-rules>
$PROJECT_RULES
</project-rules>

$CONTEXT_FILES
<review-guide>
$REVIEW_GUIDE
</review-guide>

Post the review as ONE review submission containing both inline comments and the overall summary, using the GitHub API:

gh api repos/$BASE_REPO/pulls/$PR_NUMBER/reviews -X POST --input <json-file>

with a JSON payload like: {\"event\": \"COMMENT\", \"body\": \"<overall summary>\", \"comments\": [{\"path\": \"<file>\", \"line\": <line>, \"side\": \"RIGHT\", \"body\": \"<finding>\"}, ...]}

- Inline comment lines must be part of the diff; use 'start_line' + 'line' for multi-line ranges.
- End the review body with 'Generated with [Claude Code](https://claude.com/claude-code)'."

# Run in the background and `wait`: a foreground child would block the shell so
# that INT/TERM traps only fire after it exits, which defeats the cleanup when
# the reviewer is the thing that hung.
claude --model "$REVIEW_MODEL" -p "$REVIEW_PROMPT" &
REVIEWER_PID=$!
wait "$REVIEWER_PID"
REVIEW_EC=$?
REVIEWER_PID=
exit $REVIEW_EC

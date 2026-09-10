#!/bin/zsh
source /Users/hackartist/.zshrc

PR_NUMBER=$1
PR_URL=$2

# The URL is optional: callers that only know the PR number (n8n passing
# {{ $json.body.number }}) get it built against DEFAULT_REPO. Pass the real URL
# whenever you have it — it is what makes this script work for other repos.
DEFAULT_REPO="${DEFAULT_REPO:-biyard/asset}"

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

# Run in the background and `wait`: a foreground child would block the shell so
# that INT/TERM traps only fire after it exits, which defeats the cleanup when
# the reviewer is the thing that hung.
claude --model "$REVIEW_MODEL" -p "Review the pull request $PR_URL. Use 'gh pr diff $PR_NUMBER' to get the full diff and read the surrounding code in this checkout for context. Focus on real problems, not style nits or praise.

WRITE THE REVIEW IN THE AUTHOR'S LANGUAGE. Run 'gh pr view $PR_NUMBER --json body,title' and detect the language the author wrote the PR description in — Korean or English. Write every inline comment and the summary body in that language. If the description is empty or too short to tell, fall back to the language of the commit messages, and to English if that is also inconclusive.

DO NOT REVIEW GitHub Actions workflow files (.github/workflows/**). The diff shows only the changed hunks of those files, which is not enough to judge whether the surrounding shell or YAML is correct, and reviewing them has produced false positives. Skip them entirely — no inline comments, no mention in the summary.

FIRST, load this checkout's own conventions before reviewing anything:
- Read CLAUDE.md at the repo root (and AGENTS.md if it exists).
- Read every convention file under .claude/rules/conventions/ and the review workflow at .claude/rules/workflows/code-review.md if present.
- These files are the project's mandatory conventions. A diff that violates them is a first-class finding, even when the code is otherwise correct.
- If no CLAUDE.md or .claude/rules/ exists in this checkout, skip this step and review on general merit only.

Check the following:

1. Correctness: bugs, logic errors, security vulnerabilities, race conditions, performance issues, and violations of existing code conventions.
2. Software design: are appropriate software patterns applied? Is code duplication minimized? Is the code written with reusability in mind, and does it reuse existing code in this repository instead of reimplementing it?
3. Data modeling (SQL/NoSQL): is the data model appropriate for the storage type? In SQL, flag columns that merely store values derivable from aggregate queries (sum, count, avg, etc.) instead of being computed on demand. Verify relationships between tables/collections are appropriate, and that indexes properly cover the queries introduced or changed by this PR.
4. Rust code: flag functions that should be trait implementations (e.g. conversion functions named from_x/to_x that should implement From<T>/Into<T> or TryFrom<T>). Check whether macros are used appropriately to manage repetitive code patterns, and point out repeated boilerplate that an existing macro in the codebase already covers.
   - Don't implement and use 'fn type1_from_type2(Type2)->Type1' or 'fn type1_to_type2(Type1)->Type2'. Instead of it, utilize trait as From<Type2>/Into<Type2>.
   - ERROR TYPES: flag any handler that builds a gRPC error inline from a string — tonic's Status::internal(format!(...)), Status::unknown(e.to_string()) and the like. The frontend cannot branch on an opaque internal-error string. The required shape is a dedicated error enum for the domain (DealError, WorkspaceError, ...) with one variant per failure the caller must distinguish, plus a From<DomainError> for tonic::Status (or Into) implementation that maps each variant to the right gRPC code. Handlers return the domain error and let the conversion produce the Status. When you flag this, name the variants the diff's failure cases imply so the author has a concrete starting point.
5. Convention compliance: verify the diff satisfies the conventions documented in this checkout's CLAUDE.md and files in .claude/rules/. When you flag a violation, cite the specific rule file (e.g. 'conventions/styling.md') so the author can look it up.
6. Comment quality. This rule outranks the surrounding code: a file already full of comments that break it is a file to fix, not a licence to add more. A violation is a first-class finding.
   - LANGUAGE: every comment and doc comment must be English, in every language and every file, no matter what the rest of the file, the repo, or the team writes in.
   - PLACEMENT: comments are documentation, not narration. They go ABOVE the item they document (function, type, module, field). A function's comment states its purpose, parameters, return value, and usage.
   - NOTHING INSIDE A FUNCTION BODY. Not a restatement of the next line, and not rationale either — 'why this ordering', 'why this gate', 'what breaks otherwise' are still comments glued to a statement. Reasoning that is a property of the function gets compressed into that function's doc comment; design history belongs in a spec or plan file; anything that fits neither is not worth keeping. The sole exception is a structural banner dividing a long impl or module into named sections, which is navigation rather than narration.
   - ROT: flag any comment that must change whenever the code changes, or that merely repeats the identifier it sits on. If the rule cannot be stated above the level of the implementation, no comment is the correct answer.
   - SYNTAX: use the language's own documentation syntax so tooling can extract it — JSDoc/TSDoc (/** ... */) for JavaScript/TypeScript, rustdoc (/// for items, //! for modules) for Rust, and the ecosystem standard elsewhere (Python docstrings, GoDoc, Javadoc, KDoc).
   - WHOLE-FILE SCOPE: when the diff touches a file, that entire file's comments must be brought up to this rule, not only the added lines — wrong-language comments translated, line-narration deleted or lifted into a doc comment on the enclosing item, ad-hoc syntax converted to the language's documentation syntax. This deliberately overrides any project convention saying existing comments are not to be converted. A file the diff does not touch stays as it is.

7. BFF endpoint architecture. Apply this check only when the checkout actually has server/src/api/core_rpc.rs and packages/ts-bridges/; skip it silently otherwise. The BFF no longer grows per-feature HTTP endpoints — core and plugin traffic go through unified RPC entry points, and parameter types are agreed directly between the final gRPC service and the frontend instead of being re-declared at the BFF layer.
   - Flag any new HTTP route, handler, or endpoint module added under server/src/api/ (and registered in server/src/api/mod.rs) that exists to expose a new feature operation. The intended shape is to carry that operation over server/src/api/core_rpc.rs or server/src/api/plugin_rpc.rs.
   - The TypeScript counterparts are packages/ts-bridges/src/handlers/coreRpcHandler.ts and pluginRpcHandler.ts, the useCoreRpc hook, and the CoreRpcRequest/CoreRpcResponse and PluginRpcRequest/PluginRpcResponse types. A new per-operation handler that opens its own BFF endpoint is the anti-pattern; a new RPC method over the existing unified endpoint is correct.
   - Do NOT ask the author to add BFF-level DTOs or validation mirroring the gRPC request/response. That type contract is between the gRPC service and the frontend, and duplicating it at the BFF is itself a finding.
   - The pre-existing per-feature modules (assets.rs, search.rs, storages.rs, web_crawler.rs and their _types/_grpc siblings) are legacy. Do not demand their migration in an unrelated PR — but do not accept a new sibling added alongside them either.
   - When flagging this, name the RPC entry point the author should route through, so the comment is actionable.
   - WHERE NEW IMPLEMENTATION BELONGS. The server/ package is the BFF: its job is to expose core RPC and plugin RPC, not to hold feature logic. Implementing a feature normally does not touch server/ at all. So flag new feature implementation landing under server/src/features/ — new models, services, controllers, or types added there. It belongs in the owning plugin under plugins/, or in its own backend service under server-apps/. If a refactor is what pulls logic out of server/ and into plugins/ or server-apps/, that is the desired direction and is not a finding. Judge this by what the diff ADDS to server/: a PR that both adds a server-apps/ service and grows server/src/features/ for the same feature has put the implementation in two places, and the server/ half is the part to question.
   - Generated TypeScript placement is covered separately in check 9.

8. PR scope. Specification and plan documents ship in a stacked PR, and the implementation that follows them should be the top of the stacked PR which runs CI/CD. The point is that a spec gets reviewed as a spec — on whether the design is right — before anyone reviews code written against it; mixing them buries the design discussion under implementation detail.
   - Flag a PR that changes both spec/plan documents and implementation code. Typical spec/plan paths are docs/**/spec.md, docs/**/plan.md, and design or plan documents under docs/. Ask the author to split the document changes into a separate stacked PR that lands first.
   - Report this ONCE in the summary body as a scope finding, naming the document files that should be split out. Do not repeat it as an inline comment on each document.
   - A PR that only changes documents is correctly scoped — say nothing. A PR that only changes code is correctly scoped too.
   - Do NOT use this to demand that an implementation PR add missing documentation: that would push it back toward the mixed scope this rule exists to prevent. Judging the spec's own content is the job of the spec PR, not this one.

9. Generated TypeScript placement. TypeScript that a Rust crate emits through ts-rs must land in the shared bridge package (packages/ts-bridges/src/types/), which is what the frontend imports from. Emitting it into the Rust crate's own directory is wrong.
   - Flag any ts-rs attribute the diff adds or changes whose export_to keeps the output inside the crate — ts(export, export_to = \"types/\") in a server-apps or server crate drops generated .ts files into server-apps/<service>/types/, next to Rust sources that nothing in the frontend build resolves.
   - AN EXISTING SIBLING DOING THIS DOES NOT MAKE IT CORRECT. Some crates already carry a types/ directory of generated .ts; that is the defect spreading, not a convention to match. Do not dismiss this finding on the grounds that another crate looks the same, and do not require the author to fix the pre-existing ones — only what this diff adds.
   - The generated .ts files carry a 'generated by ts-rs, do not edit this file manually' header. The fix is the export_to path in the Rust source. NEVER tell the author to move, edit, or delete a generated file, and never anchor an inline comment to one.
   - Anchor the comment to the Rust line carrying the ts-rs attribute.

Before posting, PRUNE unnecessary comments — a noisy review is worse than a short one. Draft your findings, then drop every comment that is not worth the author's attention. Remove a comment if ANY of these is true:
- It is a pure style/formatting nit that a linter or formatter already enforces (rustywind, rustfmt, prettier, etc.).
- It is praise, a restatement of what the code does, or a 'consider'/'you could' suggestion with no concrete defect behind it.
- It duplicates another comment or the overall summary, or repeats the same issue at multiple sites — collapse those into ONE comment that names the pattern.
- It is out of scope: it targets pre-existing code the diff does not touch, or asks for work beyond this PR's intent. EXCEPTION: comment-rule violations (check 6) anywhere in a file the diff touches are in scope and must survive pruning, even on lines the diff did not change.
- It is speculative ('this might break if...') without a concrete, plausible failure path in this codebase.
- It restates a rule without an actual violation in the diff.
Keep a comment only when it is anchored to a real defect or a concrete convention violation at a specific diff line. If after pruning there are no substantive inline comments, say so plainly in the summary rather than manufacturing filler.

Post the review as ONE review submission containing both inline comments and an overall summary, using the GitHub API:

gh api repos/$BASE_REPO/pulls/$PR_NUMBER/reviews -X POST --input <json-file>

with a JSON payload like: {\"event\": \"COMMENT\", \"body\": \"<overall summary>\", \"comments\": [{\"path\": \"<file>\", \"line\": <line>, \"side\": \"RIGHT\", \"body\": \"<finding>\"}, ...]}

- Each finding that maps to a specific location in the diff goes into 'comments' as an inline comment anchored to that file and line (lines must be part of the diff; use 'start_line' + 'line' for multi-line ranges).
- The 'body' is the overall assessment of the PR: what it does, whether the approach is sound, cross-cutting concerns (design, data modeling, duplication), and a severity-ordered summary of the inline findings.
- If there are no significant issues, submit the review with a short body saying the changes look good and no inline comments.
- End the review body with 'Generated with [Claude Code](https://claude.com/claude-code)'." &
REVIEWER_PID=$!
wait "$REVIEWER_PID"
REVIEW_EC=$?
REVIEWER_PID=
exit $REVIEW_EC

#!/bin/zsh
source /Users/hackartist/.zshrc

PR_NUMBER=$1
PR_URL=$2
SSH_URL=$3
BRANCH=$4

WORKING_DIR="$(pwd)/github/$PR_NUMBER"

mkdir -p "$WORKING_DIR"

cd "$WORKING_DIR" || exit 1
CLONE_DIR=review

timeout=600
interval=30
elapsed=0

while [ "$elapsed" -lt "$timeout" ]; do
    if [ ! -d "$CLONE_DIR" ]; then
        echo "$CLONE_DIR does not exist, proceeding to review the PR..."
        break
    fi
    echo "Other process is reviewing the PR, waiting for $interval seconds..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
done
export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"

git clone --depth 50 --branch "$BRANCH" "$SSH_URL" "$CLONE_DIR"

cd "$CLONE_DIR" || exit 1

claude -p "Review the pull request $PR_URL. Use 'gh pr diff $PR_NUMBER' to get the full diff and read the surrounding code in this checkout for context. Focus on real problems, not style nits or praise.

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
5. Convention compliance: verify the diff satisfies the conventions documented in this checkout's CLAUDE.md and files in .claude/rules/. When you flag a violation, cite the specific rule file (e.g. 'conventions/styling.md') so the author can look it up.

Before posting, PRUNE unnecessary comments — a noisy review is worse than a short one. Draft your findings, then drop every comment that is not worth the author's attention. Remove a comment if ANY of these is true:
- It is a pure style/formatting nit that a linter or formatter already enforces (rustywind, dx fmt, prettier, etc.).
- It is praise, a restatement of what the code does, or a 'consider'/'you could' suggestion with no concrete defect behind it.
- It duplicates another comment or the overall summary, or repeats the same issue at multiple sites — collapse those into ONE comment that names the pattern.
- It is out of scope: it targets pre-existing code the diff does not touch, or asks for work beyond this PR's intent.
- It is speculative ('this might break if...') without a concrete, plausible failure path in this codebase.
- It restates a rule without an actual violation in the diff.
Keep a comment only when it is anchored to a real defect or a concrete convention violation at a specific diff line. If after pruning there are no substantive inline comments, say so plainly in the summary rather than manufacturing filler.

Post the review as ONE review submission containing both inline comments and an overall summary, using the GitHub API:

gh api repos/<owner>/<repo>/pulls/$PR_NUMBER/reviews -X POST --input <json-file>

where <owner>/<repo> is the base repository taken from $PR_URL (do NOT rely on this checkout's git remote — it may point to a fork), with a JSON payload like: {\"event\": \"COMMENT\", \"body\": \"<overall summary>\", \"comments\": [{\"path\": \"<file>\", \"line\": <line>, \"side\": \"RIGHT\", \"body\": \"<finding>\"}, ...]}

- Each finding that maps to a specific location in the diff goes into 'comments' as an inline comment anchored to that file and line (lines must be part of the diff; use 'start_line' + 'line' for multi-line ranges).
- The 'body' is the overall assessment of the PR: what it does, whether the approach is sound, cross-cutting concerns (design, data modeling, duplication), and a severity-ordered summary of the inline findings.
- If there are no significant issues, submit the review with a short body saying the changes look good and no inline comments.
- End the review body with 'Generated with [Claude Code](https://claude.com/claude-code)'."

cd "$WORKING_DIR" || exit 1
sudo rm -rf "$CLONE_DIR"

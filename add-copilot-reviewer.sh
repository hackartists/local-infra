PR_NUMBER=$1

/opt/homebrew/bin/gh pr edit --repo biyard/ratel $PR_NUMBER --add-reviewer copilot-pull-request-reviewer

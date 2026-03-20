#!/usr/bin/zsh
source /home/hackartist/.zshrc

ISSUE_URL=$2
PR_NUMBER=`gh pr create --draft --title "WIP" --body "" --json number --jq '.number'`

WORKING_DIR=github/$PR_NUMBER

mkdir -p $WORKING_DIR

cd $WORKING_DIR

# Git clone the PR branch if not exists
if [ ! -d "ratel" ]; then
    git clone --depth 1 --branch $BRANCH $SSH_URL
fi

cd ratel
git pull

npm i

claude -p "use github-issue-resolver subagent to resolve $ISSUE_URL. Push hackartists remote the branch. Then update the PR ($PR_NUMBER) " --from-pr $PR_NUMBER

echo "PR number: $PR_NUMBER"

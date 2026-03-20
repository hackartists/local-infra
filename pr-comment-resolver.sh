#!/usr/bin/zsh
source /home/hackartist/.zshrc

PR_NUMBER=$1
PR_URL=$2
WORKING_DIR=github/$PR_NUMBER

cd $WORKING_DIR/ratel

git pull

claude -p "use pr-comment--resolver subagent to resolve unresolved PR comments on $PR_URL"

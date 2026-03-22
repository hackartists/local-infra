#!/usr/bin/zsh
source /home/hackartist/.zshrc

PR_NUMBER=$1
PR_URL=$2
SSH_URL=$3
BRANCH=$4

WORKING_DIR=$(pwd)/github/$PR_NUMBER

mkdir -p $WORKING_DIR

cd $WORKING_DIR
CLONE_DIR=comment

timeout=600
interval=30
elapsed=0

while [ $elapsed -lt $timeout ]; do
    if [ ! -d "$CLONE_DIR" ]; then
        echo "$CLONE_DIR does not exist, proceeding to handle PR comments..."
        break
    fi
    echo "Other process is handling the PR comments, waiting for $interval seconds..."
    sleep $interval
    elapsed=$((elapsed + interval))
done

git clone --depth 1 --branch $BRANCH $SSH_URL $CLONE_DIR

cd $CLONE_DIR
npm i > /dev/null

cd app/ratel
envs_ratel

claude -p "use pr-comment-resolver subagent to resolve unresolved PR comments on $PR_URL. If completly handle it, resolve the comments. Then resolve comments you have handled. When replying to the comment, let me know the comment is written by ClaudeCode adding 'Generated With [Cluade Code](..)'. Finally, please update CLAUDE.md to reflect feedback for development next time." --from-pr $PR_NUMBER

cd $WORKING_DIR
sudo rm -rf $CLONE_DIR

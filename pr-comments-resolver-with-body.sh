#!/usr/bin/zsh
source /home/hackartist/.zshrc

PR_NUMBER=$1
BRANCH=$2
COMMENT_URL=$3

WORKING_DIR=$(pwd)/github/$PR_NUMBER
mkdir -p $WORKING_DIR

cd $WORKING_DIR
CLONE_DIR=issue

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

git clone --branch $BRANCH git@github.com:hackartists/ratel.git $CLONE_DIR

cd $CLONE_DIR

npm i > /dev/null

cd app/ratel
envs_ratel

claude -p "Could you fix $COMMENT_URL on $PR_NUMBER? After fix it, commit and push changes. Then please add reaction to the comment. When replying to the comment, let me know the comment is written by ClaudeCode adding 'Generated With [Cluade Code](..)'" --from-pr $PR_NUMBER

cd $WORKING_DIR
sudo rm -rf $CLONE_DIR

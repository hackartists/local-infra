#!/usr/bin/zsh
source /home/hackartist/.zshrc

ORG=$1
REPO=$2
ISSUE_NUMBER=$3
ISSUE_URL=https://github.com/$ORG/$REPO/issues/$ISSUE_NUMBER

GITHUB_WORKSPACE=$(pwd)/github

WORKING_DIR=$GITHUB_WORKSPACE/issue-$ISSUE_NUMBER
mkdir -p $WORKING_DIR

cd $WORKING_DIR
git clone git@github.com:$ORG/$REPO.git

cd $REPO
git remote add hackartists git@github.com:hackartists/$REPO.git
git branch -c issue-$ISSUE_NUMBER
git checkout issue-$ISSUE_NUMBER

git commit --allow-empty -am `WIP: Resolving an issue #$ISSUE_NUMBER`
git push hackartists issue-$ISSUE_NUMBER

PR_NUMBER=`gh pr create --draft --title "WIP" --body "" --base dev --repo $ORG/$REPO --head hackartists:issue-$ISSUE_NUMBER 2>&1 | tail -n 1 | awk -F'/' '{print $NF}'`

cd $GITHUB_WORKSPACE
mv $WORKING_DIR $GITHUB_WORKSPACE/$PR_NUMBER

WORKING_DIR=$GITHUB_WORKSPACE/$PR_NUMBER
export CARGO_TARGET_DIR=$WORKING_DIR/target

cd $WORKING_DIR/$REPO

npm i

cd app/ratel

claude -p "use github-issue-resolver subagent to resolve $ISSUE_URL. Then write Playwright testing code for the implementation. Finally, push changes to hackartists remote the branch. Then update the PR ($PR_NUMBER) " --from-pr $PR_NUMBER

gh pr ready $PR_NUMBER --repo $ORG/$REPO

cd $GITHUB_WORKSPACE
sudo rm -rf $WORKING_DIR/$REPO

echo "PR number: $PR_NUMBER"

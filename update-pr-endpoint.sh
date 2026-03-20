#!/usr/bin/zsh

source /home/hackartist/.zshrc

SSH_URL=$1
BRANCH=$2
PR_NUMBER=$3

WORKING_DIR=$(pwd)/github/$PR_NUMBER
mkdir -p $WORKING_DIR
cd $WORKING_DIR
mkdir target

export CARGO_TARGET_DIR=$WORKING_DIR/target

# Git clone the PR branch if not exists
git clone --depth 1 --branch $BRANCH $SSH_URL

cd ratel
npm i

cd app/ratel
envs_ratel

make build

export COMMIT=pr-$PR_NUMBER
export ECR=ratel
make docker

PORT=2$PR_NUMBER
CONTAINER_NAME=ratel-pr-$PR_NUMBER

# Stop and remove the existing container if it exists
if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
    docker rm -f $CONTAINER_NAME
fi

docker run -d --name $CONTAINER_NAME -p $PORT:8080 -e "IP=0.0.0.0" $ECR:$COMMIT

cd $WORKING_DIR
sudo rm -rf ratel

echo "$PORT"





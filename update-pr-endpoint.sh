#!/usr/bin/zsh

source /home/hackartist/.zshrc

SSH_URL=$1
BRANCH=$2
PR_NUMBER=$3

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

cd app/ratel
envs_ratel

make build

export COMMIT=pr-$PR_NUMBER
export ECR=ratel
make docker

PORT=2$PR_NUMBER
CONTAINER_NAME=ratel-pr-$PR_NUMBER

# Stop and remove the existing container if it exists
if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
    docker rm -f $CONTAINER_NAME
fi

docker run -d --name $CONTAINER_NAME -p $PORT:8080 -e "IP=0.0.0.0" $ECR:$COMMIT

echo "$PORT"





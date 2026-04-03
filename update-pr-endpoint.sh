#!/usr/bin/zsh

source /home/hackartist/.zshrc

SSH_URL=$1
BRANCH=$2
PR_NUMBER=$3

WORKING_DIR=$(pwd)/github/$PR_NUMBER
mkdir -p $WORKING_DIR
export CARGO_TARGET_DIR=$WORKING_DIR/target

mkdir -p $CARGO_TARGET_DIR

cd $WORKING_DIR
CLONE_DIR=pr

timeout=600
interval=30
elapsed=0

while [ $elapsed -lt $timeout ]; do
    if [ ! -d "$CLONE_DIR" ]; then
        break
    fi
    echo "Other process is handling the PR updates, waiting for $interval seconds..."
    sleep $interval
    elapsed=$((elapsed + interval))
done

if [ ! -d "$CLONE_DIR" ]; then
    git clone --depth 1 --branch $BRANCH $SSH_URL $CLONE_DIR
fi

cd $CLONE_DIR

npm i > /dev/null

cd app/ratel
envs_ratel

ln -s $CARGO_TARGET_DIR ../../target

make build > /dev/null

export COMMIT=pr-$PR_NUMBER
export ECR=ratel
make docker

PORT=2$PR_NUMBER
CONTAINER_NAME=ratel-pr-$PR_NUMBER

# Stop and remove the existing container if it exists
if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
    docker rm -f $CONTAINER_NAME
    docker image rm $ECR:$COMMIT
fi

docker run -d --restart always --name $CONTAINER_NAME -p $PORT:8080 -e "IP=0.0.0.0" $ECR:$COMMIT

cd $WORKING_DIR
sudo rm -rf $CLONE_DIR

echo "PR #$PR_NUMBER is running at http://localhost:$PORT"

timeout=60
interval=10
elapsed=0

while [ $elapsed -lt $timeout ]; do
    wget http://localhost:$PORT

    # Exit if 0 is returned, meaning the service is up
    if [ $? -eq 0 ]; then
        echo "Service is up and running!"
        exit 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
done

echo "Service did not start within $timeout seconds."
exit 1

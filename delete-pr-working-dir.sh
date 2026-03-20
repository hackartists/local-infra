#!/usr/bin/zsh

PR_NUMBER=$1
WORKING_DIR=github/$PR_NUMBER

sudo rm -rf $WORKING_DIR

CONTAINER_NAME=ratel-pr-$PR_NUMBER

docker rm -f $CONTAINER_NAME || true

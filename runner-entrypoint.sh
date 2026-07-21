#!/bin/bash
set -e

if [ ! -f ./run.sh ]; then
  curl -o actions-runner-linux-arm64-2.335.1.tar.gz -L https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-linux-arm64-2.335.1.tar.gz
  tar xzf ./actions-runner-linux-arm64-2.335.1.tar.gz
  RUNNER_ALLOW_RUNASROOT=true ./config.sh --url https://github.com/biyard --token $RUNNER_TOKEN --labels $LABELS --name $RUNNER_NAME
fi

./run.sh

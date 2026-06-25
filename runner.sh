cd runner

RUNNER_ALLOW_RUNASROOT=true ./config.sh --url https://github.com/biyard --token $RUNNER_TOKEN --labels $LABELS --name $RUNNER_NAME

./run.sh

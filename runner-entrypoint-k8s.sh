#!/bin/bash
# k8s StatefulSet runner entrypoint. State (registration files) lives on the
# per-pod PVC at /root/runner; the runner binary is (re)downloaded on first run.
set -e

ORDINAL=${HOSTNAME##*-}
export RUNNER_NAME="runner$((ORDINAL + 1))"

# Compat: some CI jobs read ~/.kube/config; synthesize one from the in-cluster SA.
if [ ! -f /root/.kube/config ] && [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  kubectl config set-cluster incluster \
    --server=https://kubernetes.default.svc \
    --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  kubectl config set-credentials runner-sa \
    --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  kubectl config set-context incluster --cluster=incluster --user=runner-sa
  kubectl config use-context incluster
fi

cd /root/runner

if [ ! -f ./run.sh ]; then
  curl -o actions-runner-linux-arm64-2.335.1.tar.gz -L \
    https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-linux-arm64-2.335.1.tar.gz
  tar xzf ./actions-runner-linux-arm64-2.335.1.tar.gz
  rm -f actions-runner-linux-arm64-2.335.1.tar.gz
fi

if [ ! -f .runner ]; then
  if [ -n "$RUNNER_TOKEN" ]; then
    RUNNER_ALLOW_RUNASROOT=true ./config.sh --url https://github.com/biyard \
      --token "$RUNNER_TOKEN" --labels "${LABELS:-linux,arm64,docker}" --name "$RUNNER_NAME" --unattended
  else
    echo "FATAL: no migrated registration state (.runner) and no RUNNER_TOKEN — refusing to start" >&2
    exit 1
  fi
fi

./run.sh

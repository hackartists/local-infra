#!/bin/bash
# Big-bang runner state migration: compose runners → k3s StatefulSet PVCs.
# Copies ONLY the registration files (.runner, .credentials*, .env, .path);
# binaries/_work are re-created by the entrypoint. Idempotent per-runner.
set -euo pipefail

cd "$(dirname "$0")"
NS=infra

for N in $(seq 0 8); do
  SRC="runners/runner$((N + 1))"
  PVC="state-runner-$N"
  POD="state-migrate-$N"

  if [ ! -f "$SRC/.runner" ]; then
    echo "SKIP $SRC: no .runner (not registered?)" >&2
    continue
  fi

  # volumeClaimTemplates 이름 규약(state-runner-<N>)으로 선생성 — STS가 그대로 입양한다.
  kubectl -n $NS get pvc $PVC >/dev/null 2>&1 || kubectl -n $NS apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  labels:
    app: runner
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
EOF

  kubectl -n $NS apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: lima-k3s-server
  containers:
    - name: sh
      image: busybox
      command: ["sleep", "600"]
      volumeMounts:
        - name: state
          mountPath: /state
  volumes:
    - name: state
      persistentVolumeClaim:
        claimName: $PVC
EOF
  kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=120s

  tar -C "$SRC" -cf - .runner .credentials .credentials_rsaparams $( [ -f "$SRC/.env" ] && echo .env ) $( [ -f "$SRC/.path" ] && echo .path ) \
    | kubectl -n $NS exec -i $POD -- tar -xf - -C /state
  kubectl -n $NS exec $POD -- ls -la /state
  kubectl -n $NS delete pod $POD --wait=false
  echo "OK: $SRC -> $PVC"
done

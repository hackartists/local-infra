# 러너 k3s 마이그레이션 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub Actions 러너 9개를 docker-compose에서 k3s StatefulSet으로 빅뱅 이관하고, docker 의존을 buildkit+registry로, PR 정적 프리뷰를 k3s로 대체한다.

**Architecture:** 공유 buildkitd(빌드) + 내부 registry pull 경로(노드 registries.yaml 미러) + pr-webroot(정적 프리뷰 nginx/PVC)를 선배치한 뒤, compose 러너를 일괄 정지하고 등록 상태 파일만 PVC로 이관해 k3s StatefulSet(replicas 9)으로 기동. 러너·buildkitd·pr-webroot 전부 lima-k3s-server 노드 고정.

**Tech Stack:** k3s v1.36.2 (arm64), helmfile+helm v4, buildkit(buildctl), local-path PVC, ingress-nginx(hostNetwork), cert-manager(Route53 DNS-01)

**Spec:** `docs/superpowers/specs/2026-08-04-runners-k3s-migration-design.md`

## Global Constraints

- 이 zsh에는 깨진 `git`/`docker` 래퍼 함수가 있음 — 반드시 `command git ...`, `command docker ...`로 실행.
- 네임스페이스 `infra`. 러너·buildkitd·pr-nginx·registry 전부 `nodeSelector: {kubernetes.io/hostname: lima-k3s-server}` — **Pi 배치 금지** (빌드 성능, RWO PVC 공유 전제).
- 러너 이름 `runner1`~`runner9`·라벨 `linux,arm64,docker` 유지 — 파드 `runner-<N>`(ordinal)이 상태 `runner<N+1>`을 사용.
- 이미지 명명 규약: 매니페스트/사람은 `registry.dev.biyard.co/<repo>:<tag>` (노드는 registries.yaml 미러로, 사람은 ingress로 pull). **클러스터 내부에서의 push는 `registry.infra.svc.cluster.local:5000/<repo>:<tag>` + `registry.insecure=true`** (인증 불필요, 같은 저장소이므로 두 이름으로 상호 pull 가능).
- registry Service 고정 `clusterIP: 10.43.200.5`.
- TLS secret: `pr-biyard-co-tls` (`*.pr.biyard.co`), ClusterIssuer `letsencrypt-route53` 재사용.
- BUILDKIT_HOST 계약: `tcp://buildkitd.infra.svc.cluster.local:1234` (클러스터 밖 전환기용 NodePort 31234).
- compose 서비스 중 **runner1~9만** 정지/제거 대상. nginx·certbot 등 다른 compose 서비스와 `runners/` 원본 디렉토리·`nginx/webroot` 원본은 보존(롤백용).
- `nginx/conf.d/miner.conf`에 무관한 uncommitted 변경이 있음 — 커밋에 섞지 말 것. `nginx/nginx.conf` 편집 시 단일 파일 바인드 마운트 특성상 reload 불가 — 일회용 컨테이너 사전 검증 후 `docker restart nginx` (Task 7에 절차 명시).
- k3s 서비스 재시작(Task 1)과 compose 러너 정지(Task 6), nginx 재시작(Task 7)은 이 계획에서 명시적으로 허용된 상태 변경임. 그 외 라이브 상태 변경 금지.

---

### Task 1: registry 고정 ClusterIP + 노드 registries.yaml 미러

**Files:**
- Modify: `k8s/charts/registry/values.yaml` (clusterIP 추가)
- Modify: `k8s/charts/registry/templates/registry.yaml` (Service에 clusterIP)
- Create: `k8s/node-config/registries.yaml` (노드 배포용 원본, 레포에 기록)

**Interfaces:**
- Produces: registry Service `10.43.200.5:5000` 고정. 노드 containerd가 `registry.dev.biyard.co/...` 이미지를 내부 http로 pull 가능 (Task 2/4/5/6이 의존).

- [ ] **Step 1: values/템플릿 수정**

`k8s/charts/registry/values.yaml`의 `image:` 줄 아래에 추가:

```yaml
# 노드 registries.yaml 미러가 이 IP를 참조하므로 고정 필수 (k8s/node-config/).
clusterIP: 10.43.200.5
```

`k8s/charts/registry/templates/registry.yaml`의 registry Service(`name: registry`) spec에 추가:

```yaml
  clusterIP: {{ .Values.clusterIP }}
```

(`spec:` 바로 아래, `selector:` 위.)

- [ ] **Step 2: Service 재생성 적용**

clusterIP는 불변 필드라 삭제 후 재생성:

```bash
kubectl -n infra delete svc registry
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra/k8s && helmfile -l name=registry apply
kubectl -n infra get svc registry -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Expected: `10.43.200.5`. (Service 삭제~재생성 사이 수 초간 registry 접근 단절 — 무해.)

- [ ] **Step 3: registries.yaml 작성 및 lima 노드 적용**

`k8s/node-config/registries.yaml` (레포 기록용 원본):

```yaml
# /etc/rancher/k3s/registries.yaml — 양 노드 공통.
# registry.dev.biyard.co pull을 클러스터 내부 registry로 직결(http, 무인증).
# 적용 후 k3s(서버)/k3s-agent(파이) 서비스 재시작 필요.
mirrors:
  "registry.dev.biyard.co":
    endpoint:
      - "http://10.43.200.5:5000"
```

lima 노드 적용:

```bash
limactl shell k3s-server -- sudo mkdir -p /etc/rancher/k3s
limactl shell k3s-server -- sudo tee /etc/rancher/k3s/registries.yaml < k8s/node-config/registries.yaml
limactl shell k3s-server -- sudo systemctl restart k3s
kubectl get nodes   # 재시작 후 Ready 복귀 확인 (수십 초 소요 가능)
```

주의: k3s 재시작 동안 lima 노드의 hostNetwork ingress도 수십 초 끊김(miner/dev 도메인 순단) — 허용됨.

- [ ] **Step 4: Pi 노드 적용 (실패 시 폴백)**

```bash
ssh hackartist@192.168.0.34 'sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/registries.yaml && sudo systemctl restart k3s-agent' < k8s/node-config/registries.yaml
```

`ssh 192.168.0.34`, `ssh hackartist-pi`, `ssh pi@192.168.0.34`도 시도해볼 것. **전부 실패하면 lima만 적용하고 보고서에 명시**(고정 워크로드는 전부 lima라 기능 영향 없음; Pi는 후속 수동 적용).

- [ ] **Step 5: 회귀 확인**

```bash
kubectl -n infra get pods | grep -cE "Running|Completed"
curl -s -o /dev/null -w '%{http_code}\n' -I https://s3.miner.biyard.co/
```

Expected: 파드 전부 정상, ingress 200 복귀.

- [ ] **Step 6: Commit**

```bash
command git add k8s/charts/registry k8s/node-config/registries.yaml
command git commit -m "feat(k8s): pin registry clusterIP + node registries.yaml mirror for internal pulls"
```

---

### Task 2: buildkitd 차트 + 빌드/pull 경로 end-to-end 검증

**Files:**
- Create: `k8s/charts/buildkitd/Chart.yaml`
- Create: `k8s/charts/buildkitd/values.yaml`
- Create: `k8s/charts/buildkitd/templates/buildkitd.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Consumes: Task 1의 registry 미러
- Produces: Service `buildkitd.infra.svc.cluster.local:1234`, NodePort `192.168.0.54:31234`. 빌드 계약(README·Task 4·워크플로우 가이드가 사용): `buildctl --addr tcp://buildkitd.infra.svc.cluster.local:1234 build --frontend dockerfile.v0 --local context=. --local dockerfile=. --output type=image,name=registry.infra.svc.cluster.local:5000/<repo>:<tag>,push=true,registry.insecure=true`

- [ ] **Step 1: 차트 작성**

`k8s/charts/buildkitd/Chart.yaml`:

```yaml
apiVersion: v2
name: buildkitd
description: Shared BuildKit daemon for CI image builds (runners + external via NodePort)
type: application
version: 0.1.0
appVersion: "0.17"
```

`k8s/charts/buildkitd/values.yaml`:

```yaml
nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

image: moby/buildkit:latest
cacheSize: 50Gi
storageClass: local-path
nodePort: 31234
```

`k8s/charts/buildkitd/templates/buildkitd.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: buildkitd-cache
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {{ .Values.storageClass }}
  resources:
    requests:
      storage: {{ .Values.cacheSize }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: buildkitd
spec:
  replicas: 1
  strategy:
    type: Recreate   # RWO 캐시 PVC 공유 불가 → 동시 2개 금지
  selector:
    matchLabels:
      app: buildkitd
  template:
    metadata:
      labels:
        app: buildkitd
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      containers:
        - name: buildkitd
          image: {{ .Values.image }}
          args:
            - --addr
            - tcp://0.0.0.0:1234
          securityContext:
            privileged: true
          ports:
            - containerPort: 1234
          readinessProbe:
            exec:
              command: ["buildctl", "--addr", "tcp://127.0.0.1:1234", "debug", "workers"]
            periodSeconds: 10
          volumeMounts:
            - name: cache
              mountPath: /var/lib/buildkit
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: buildkitd-cache
---
apiVersion: v1
kind: Service
metadata:
  name: buildkitd
spec:
  selector:
    app: buildkitd
  ports:
    - port: 1234
      targetPort: 1234
---
# 전환기: 클러스터 밖(compose 러너, 개발자 Mac)에서의 빌드용
apiVersion: v1
kind: Service
metadata:
  name: buildkitd-nodeport
spec:
  type: NodePort
  selector:
    app: buildkitd
  ports:
    - port: 1234
      targetPort: 1234
      nodePort: {{ .Values.nodePort }}
```

- [ ] **Step 2: helmfile release 추가 + 배포**

`k8s/helmfile.yaml`의 `- name: registry` 블록 아래에 추가:

```yaml
  - name: buildkitd
    namespace: infra
    chart: ./charts/buildkitd
```

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra/k8s && helm template buildkitd ./charts/buildkitd >/dev/null && helmfile -l name=buildkitd apply
kubectl -n infra rollout status deploy/buildkitd --timeout=300s
```

- [ ] **Step 3: Mac에 buildctl 준비**

```bash
buildctl --version || brew install buildkit
```

- [ ] **Step 4: end-to-end 스모크 — 빌드→push→k3s pull 기동**

```bash
SCRATCH=$(mktemp -d)
printf 'FROM alpine:latest\nRUN echo built-by-buildkitd > /hello\nCMD ["cat","/hello"]\n' > $SCRATCH/Dockerfile
buildctl --addr tcp://192.168.0.54:31234 build \
  --frontend dockerfile.v0 --local context=$SCRATCH --local dockerfile=$SCRATCH \
  --output type=image,name=registry.infra.svc.cluster.local:5000/smoke/bk:1,push=true,registry.insecure=true
kubectl -n infra run bk-smoke --rm -i --restart=Never \
  --image=registry.dev.biyard.co/smoke/bk:1 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"lima-k3s-server"}}}'
```

Expected: push 성공 로그, pod 출력 `built-by-buildkitd` — **push는 내부 이름, pull은 registry.dev.biyard.co 이름**으로 성공해야 Task 1 미러까지 검증됨. Pi에 registries.yaml이 적용됐다면 nodeSelector를 hackartist-pi로 바꿔 1회 더 확인(선택).

- [ ] **Step 5: Commit**

```bash
command git add k8s/charts/buildkitd k8s/helmfile.yaml
command git commit -m "feat(k8s): shared buildkitd for CI builds (tcp 1234, nodeport 31234)"
```

---

### Task 3: pr.biyard.co TLS + pr-webroot 정적 프리뷰 서버

**Files:**
- Modify: `k8s/charts/tls/values.yaml` (certs에 pr.biyard.co)
- Create: `k8s/charts/pr-webroot/Chart.yaml`
- Create: `k8s/charts/pr-webroot/values.yaml`
- Create: `k8s/charts/pr-webroot/templates/pr-webroot.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `letsencrypt-route53`, ingress-nginx
- Produces: PVC `pr-webroot`(러너 파드가 `/root/nginx`로 마운트 — Task 5), Secret `pr-biyard-co-tls`, `*.pr.biyard.co` ingress. 콘텐츠 루트 규약: PVC 루트 = 구 `nginx/webroot` 루트 (`<svc>-<pr>/` 디렉토리들).

- [ ] **Step 1: 잔재 ACME TXT 정리 후 cert 존 추가**

기존 certbot 수동 발급(`*.pr.biyard.co`)의 TXT 잔재가 있으면 발급이 막힌다:

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z01931081NPCG088QNZXX \
  --query "ResourceRecordSets[?Name=='_acme-challenge.pr.biyard.co.']" --output json
```

레코드가 있으면 동일 값으로 DELETE (Task 6 스펙의 miner 전례와 동일한 방식 — `aws route53 change-resource-record-sets --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":<위에서 출력된 레코드 그대로>}]}'`).

`k8s/charts/tls/values.yaml`의 `certs:` 리스트에 추가:

```yaml
  - dnsZone: pr.biyard.co
    secretName: pr-biyard-co-tls
```

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra/k8s && helmfile -l name=tls apply
kubectl -n infra wait --for=condition=Ready certificate/pr-biyard-co --timeout=600s
```

Expected: Ready=True, secret `pr-biyard-co-tls` 존재. (miner/dev Certificate는 변경 없음 — helm diff에서 재발급이 보이면 중단하고 원인 확인.)

- [ ] **Step 2: pr-webroot 차트 작성**

`k8s/charts/pr-webroot/Chart.yaml`:

```yaml
apiVersion: v2
name: pr-webroot
description: Per-PR static preview hosting (replaces Mac nginx asset-pr.conf static vhosts)
type: application
version: 0.1.0
appVersion: "1"
```

`k8s/charts/pr-webroot/values.yaml`:

```yaml
nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

storage: 50Gi
storageClass: local-path

ingress:
  className: nginx
  host: "*.pr.biyard.co"
  tlsHost: "*.pr.biyard.co"
  tlsSecret: pr-biyard-co-tls
```

`k8s/charts/pr-webroot/templates/pr-webroot.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pr-webroot
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {{ .Values.storageClass }}
  resources:
    requests:
      storage: {{ .Values.storage }}
---
# 구 nginx/conf.d/asset-pr.conf의 정적 서빙 규칙 이식.
# - asset-report-<pr>: 정적 SPA
# - <svc>-<pr>: 정적 SPA + /api → PROD https://<svc>.biyard.co (원 URI 유지)
#   + /assets-local- → k3s minio (프리사인 업로드 Host 유지)
# 구 asset-<pr> full-stack(compose e2e) 블록은 빅뱅으로 폐기 — generic 규칙으로 수렴.
# essence-<pr> 등 per-PR full-stack은 각자 exact-host Ingress가 이 wildcard보다
# 우선 매칭되므로 여기 올 일이 없다.
apiVersion: v1
kind: ConfigMap
metadata:
  name: pr-nginx-conf
data:
  default.conf: |
    server {
        listen 80;
        server_name ~^asset-report-(?<pr>\d+)\.pr\.biyard\.co$;
        location / {
            root /usr/share/nginx/html/asset-report-$pr;
            try_files $uri $uri/ /index.html;
        }
    }
    server {
        listen 80;
        server_name ~^(?<svc>[a-z0-9]+)-(?<pr>\d+)\.pr\.biyard\.co$;

        resolver 8.8.8.8 1.1.1.1 valid=300s;
        resolver_timeout 5s;

        location /api/ {
            set $api_backend "$svc.biyard.co";
            proxy_pass https://$api_backend;
            proxy_ssl_server_name on;
            proxy_set_header Host $api_backend;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location /assets-local- {
            proxy_pass http://minio.infra.svc.cluster.local:9000;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            client_max_body_size 0;
            proxy_request_buffering off;
            proxy_buffering off;
        }

        location / {
            root /usr/share/nginx/html/$svc-$pr;
            try_files $uri $uri/ /index.html;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pr-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pr-nginx
  template:
    metadata:
      labels:
        app: pr-nginx
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: webroot
              mountPath: /usr/share/nginx/html
              readOnly: true
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: webroot
          persistentVolumeClaim:
            claimName: pr-webroot
        - name: conf
          configMap:
            name: pr-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: pr-nginx
spec:
  selector:
    app: pr-nginx
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pr-webroot
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
    - hosts: [{{ .Values.ingress.tlsHost | quote }}]
      secretName: {{ .Values.ingress.tlsSecret }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pr-nginx
                port:
                  number: 80
```

- [ ] **Step 3: helmfile release 추가 + 배포**

`k8s/helmfile.yaml`의 `- name: buildkitd` 블록 아래에 추가:

```yaml
  - name: pr-webroot
    namespace: infra
    chart: ./charts/pr-webroot
```

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra/k8s && helm template pr-webroot ./charts/pr-webroot >/dev/null && helmfile -l name=pr-webroot apply
kubectl -n infra rollout status deploy/pr-nginx --timeout=180s
```

- [ ] **Step 4: 기존 webroot 콘텐츠 복사 (~753MB)**

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra
POD=$(kubectl -n infra get pod -l app=pr-nginx -o jsonpath='{.items[0].metadata.name}')
kubectl -n infra exec $POD -- sh -c 'chmod 777 /usr/share/nginx/html' 2>/dev/null || true
tar -C nginx/webroot -cf - . | kubectl -n infra exec -i deploy/pr-nginx -- tar -xf - -C /usr/share/nginx/html
kubectl -n infra exec deploy/pr-nginx -- sh -c 'ls /usr/share/nginx/html | head -5; ls /usr/share/nginx/html | wc -l'
```

주의: pr-nginx의 webroot 마운트가 readOnly라 exec 쓰기가 거부되면, PVC를 rw로 마운트한 임시 pod(busybox, nodeSelector lima)를 만들어 동일한 tar 파이프로 복사한 뒤 삭제한다. 디렉토리 수가 호스트 `ls nginx/webroot | wc -l`과 일치해야 함.

- [ ] **Step 5: k3s측 서빙 검증 (--resolve, 엣지 전환 전)**

```bash
SAMPLE=$(ls nginx/webroot | grep -E '^[a-z0-9]+-[0-9]+$' | head -1)
curl -sk -o /dev/null -w '%{http_code}\n' --resolve $SAMPLE.pr.biyard.co:443:192.168.0.54 https://$SAMPLE.pr.biyard.co/
curl -sv --resolve $SAMPLE.pr.biyard.co:443:192.168.0.54 https://$SAMPLE.pr.biyard.co/ -o /dev/null 2>&1 | grep -E "subject:"
```

Expected: 200, subject `CN=*.pr.biyard.co`.

- [ ] **Step 6: Commit**

```bash
command git add k8s/charts/tls/values.yaml k8s/charts/pr-webroot k8s/helmfile.yaml
command git commit -m "feat(k8s): pr-webroot static preview server + *.pr.biyard.co wildcard cert"
```

---

### Task 4: 러너 이미지 (Dockerfile.runner-k8s) 빌드·push

**Files:**
- Create: `Dockerfile.runner-k8s`
- Create: `runner-entrypoint-k8s.sh`

**Interfaces:**
- Consumes: Task 2 buildkitd(NodePort 31234), registry
- Produces: 이미지 `registry.dev.biyard.co/infra/runner:v1` (pull 이름; push는 내부 이름). Task 5 StatefulSet이 사용. entrypoint는 ordinal→RUNNER_NAME 매핑, in-cluster kubeconfig 생성, 상태 파일 존재 시 등록 생략.

- [ ] **Step 1: `runner-entrypoint-k8s.sh` 작성**

```bash
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
```

- [ ] **Step 2: `Dockerfile.runner-k8s` 작성**

```dockerfile
# k8s runner image: Dockerfile.runner minus the docker CLI/daemon deps,
# plus kubectl/helm/buildctl for the buildkit+registry build contract.
FROM public.ecr.aws/sam/build-provided.al2023:latest

RUN cd /root && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > install.sh && \
    sh install.sh -y && \
    dnf install dotnet-sdk-10.0 openssl-devel gcc gcc-c++ make cmake git diffutils patch binutils libcurl-devel pkgconf-pkg-config tar gzip which findutils jq -y

RUN curl -L "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
    BK=$(curl -s https://api.github.com/repos/moby/buildkit/releases/latest | jq -r .tag_name) && \
    curl -L "https://github.com/moby/buildkit/releases/download/${BK}/buildkit-${BK}.linux-arm64.tar.gz" \
      | tar -xz -C /usr/local && \
    buildctl --version

COPY runner-entrypoint-k8s.sh /usr/local/bin/runner-entrypoint-k8s.sh
RUN chmod +x /usr/local/bin/runner-entrypoint-k8s.sh

ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUNNER_ALLOW_RUNASROOT=true
ENV BUILDKIT_HOST=tcp://buildkitd.infra.svc.cluster.local:1234
WORKDIR /root/runner

CMD ["/usr/local/bin/runner-entrypoint-k8s.sh"]
```

주의: buildkit 릴리스 tarball은 `bin/` 하위로 풀리므로 `-C /usr/local` → `/usr/local/bin/buildctl`. `buildctl --version`이 빌드 시 검증한다. get-helm-3가 arm64를 자동 감지한다.

- [ ] **Step 3: buildkitd로 빌드·push (rust/dotnet 설치로 10분+ 소요 가능)**

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra
cp Dockerfile.runner-k8s /tmp/runner-build-ctx/Dockerfile 2>/dev/null || { mkdir -p /tmp/runner-build-ctx && cp Dockerfile.runner-k8s /tmp/runner-build-ctx/Dockerfile; }
cp runner-entrypoint-k8s.sh /tmp/runner-build-ctx/
buildctl --addr tcp://192.168.0.54:31234 build \
  --frontend dockerfile.v0 --local context=/tmp/runner-build-ctx --local dockerfile=/tmp/runner-build-ctx \
  --output type=image,name=registry.infra.svc.cluster.local:5000/infra/runner:v1,push=true,registry.insecure=true
```

Expected: push 성공. 실패 시 로그로 디버그(al2023 arm64 패키지 누락 등) 후 Dockerfile 수정.

- [ ] **Step 4: pull 검증**

```bash
kubectl -n infra run runner-img-smoke --rm -i --restart=Never \
  --image=registry.dev.biyard.co/infra/runner:v1 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"lima-k3s-server"}}}' \
  --command -- sh -c 'kubectl version --client && buildctl --version && helm version --short && cargo --version'
```

Expected: 네 도구 버전 출력 (entrypoint가 아닌 command 오버라이드라 등록 로직은 타지 않음).

- [ ] **Step 5: Commit**

```bash
command git add Dockerfile.runner-k8s runner-entrypoint-k8s.sh
command git commit -m "feat(runners): k8s runner image — docker removed, kubectl/helm/buildctl added"
```

---

### Task 5: runners 차트 (StatefulSet + SA/RBAC, replicas 0)

**Files:**
- Create: `k8s/charts/runners/Chart.yaml`
- Create: `k8s/charts/runners/values.yaml`
- Create: `k8s/charts/runners/templates/rbac.yaml`
- Create: `k8s/charts/runners/templates/statefulset.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Consumes: 이미지 `registry.dev.biyard.co/infra/runner:v1`(Task 4), PVC `pr-webroot`(Task 3), buildkitd svc(Task 2)
- Produces: StatefulSet `runner`(초기 replicas 0), volumeClaimTemplates `state` → PVC 이름 규약 `state-runner-<N>` (Task 6 이관 스크립트가 이 이름으로 사전 생성), SA `runner`.

- [ ] **Step 1: 차트 작성**

`k8s/charts/runners/Chart.yaml`:

```yaml
apiVersion: v2
name: runners
description: Self-hosted GitHub Actions runners (static 9, migrated from docker-compose)
type: application
version: 0.1.0
appVersion: "2.335.1"
```

`k8s/charts/runners/values.yaml`:

```yaml
nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

image: registry.dev.biyard.co/infra/runner:v1
# 컷오버(Task 6) 때 9로 올린다. 그 전엔 파드 0.
replicas: 0
stateSize: 20Gi
storageClass: local-path

resources:
  requests:
    cpu: "1"
    memory: 2Gi
```

`k8s/charts/runners/templates/rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: runner
---
# 프리뷰 배포 잡이 임의 네임스페이스를 만들고 지우므로 우선 cluster-admin.
# (기존 compose 러너가 cluster-admin kubeconfig를 마운트하던 것과 동등.
#  범위 축소는 스펙 §3.3의 후속 항목.)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: runner-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: runner
    namespace: infra
```

`k8s/charts/runners/templates/statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: runner
spec:
  serviceName: runner
  replicas: {{ .Values.replicas }}
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: runner
  template:
    metadata:
      labels:
        app: runner
    spec:
      serviceAccountName: runner
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      containers:
        - name: runner
          image: {{ .Values.image }}
          resources:
{{ toYaml .Values.resources | indent 12 }}
          env:
            - name: LABELS
              value: linux,arm64,docker
          volumeMounts:
            - name: state
              mountPath: /root/runner
            # 구 compose 마운트 ./nginx/webroot:/root/nginx 경로 호환 —
            # CI 잡이 여기 쓰면 pr-nginx가 즉시 서빙한다.
            - name: pr-webroot
              mountPath: /root/nginx
      volumes:
        - name: pr-webroot
          persistentVolumeClaim:
            claimName: pr-webroot
  volumeClaimTemplates:
    - metadata:
        name: state
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.storageClass }}
        resources:
          requests:
            storage: {{ .Values.stateSize }}
---
apiVersion: v1
kind: Service
metadata:
  name: runner
spec:
  clusterIP: None
  selector:
    app: runner
```

- [ ] **Step 2: helmfile release 추가 + 배포(replicas 0)**

`k8s/helmfile.yaml`의 `- name: pr-webroot` 블록 아래에 추가:

```yaml
  - name: runners
    namespace: infra
    chart: ./charts/runners
```

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra/k8s && helm template runners ./charts/runners >/dev/null && helmfile -l name=runners apply
kubectl -n infra get sts runner -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n infra get sa runner
```

Expected: replicas `0`, SA 존재. 파드는 아직 없음(정상 — 컷오버는 Task 6).

- [ ] **Step 3: Commit**

```bash
command git add k8s/charts/runners k8s/helmfile.yaml
command git commit -m "feat(k8s): runner statefulset chart (replicas 0 pre-cutover, SA cluster-admin)"
```

---

### Task 6: 빅뱅 컷오버 — 상태 이관 + 러너 기동

**Files:**
- Create: `migrate-runner-state.sh`

**Interfaces:**
- Consumes: Task 4 이미지, Task 5 StatefulSet, 기존 `runners/runner1..9` 상태
- Produces: k3s에서 runner1~9 가동(GitHub org에 Online). **이 태스크부터 compose 러너는 정지 상태이며 docker 의존 CI 잡은 실패하기 시작한다(스펙상 감수).**

- [ ] **Step 1: `migrate-runner-state.sh` 작성**

```bash
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
```

```bash
chmod +x migrate-runner-state.sh
```

- [ ] **Step 2: compose 러너 정지 (컷오버 시작)**

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra
command docker compose stop runner1 runner2 runner3 runner4 runner5 runner6 runner7 runner8 runner9
command docker ps --format '{{.Names}}' | grep -c runner || echo "0 runners in docker (good)"
```

Expected: compose 러너 9개 전부 Exited. (`stop`만 — `rm` 금지, 롤백용.)

- [ ] **Step 3: 상태 이관 실행**

```bash
./migrate-runner-state.sh
kubectl -n infra get pvc | grep state-runner | wc -l
```

Expected: 각 러너 `OK` 로그와 PVC 9개. `.runner` 없는 디렉토리가 있으면 SKIP 로그 확인 후 해당 러너만 RUNNER_TOKEN 재등록 대상으로 보고서에 기록.

- [ ] **Step 4: 러너 기동**

```bash
cd k8s && helmfile -l name=runners apply --set replicas=9 2>/dev/null || kubectl -n infra scale sts runner --replicas=9
kubectl -n infra rollout status sts/runner --timeout=600s
for i in $(seq 0 8); do kubectl -n infra logs runner-$i --tail=3 | grep -E "Listening for Jobs|Runner connect" && echo "runner-$i OK"; done
```

Expected: 9개 파드 Running, 각 로그에 `Listening for Jobs`. 참고: values의 replicas는 0이므로 다음 `helmfile apply`가 0으로 되돌리지 않게 **`k8s/charts/runners/values.yaml`의 `replicas: 0`을 `replicas: 9`로 수정**하고 함께 커밋한다(주석도 갱신).

- [ ] **Step 5: GitHub 등록 상태 검증**

```bash
gh api /orgs/biyard/actions/runners --jq '.runners[] | "\(.name) \(.status)"' 2>/dev/null | sort
```

Expected: runner1~9 전부 `online`. gh 권한이 없으면 실패해도 됨 — 파드 로그의 `Listening for Jobs`가 1차 근거이며, 보고서에 gh 확인 불가를 명시.

- [ ] **Step 6: Commit**

```bash
command git add migrate-runner-state.sh k8s/charts/runners/values.yaml
command git commit -m "feat(runners): big-bang cutover to k3s statefulset (state migrated, replicas 9)"
```

---

### Task 7: Mac nginx — *.pr.biyard.co SNI 전환

**Files:**
- Modify: `nginx/nginx.conf` (stream map에 `.pr.biyard.co` 1줄)

**Interfaces:**
- Consumes: Task 3의 pr-webroot ingress + 인증서
- Produces: 공인 `*.pr.biyard.co` 트래픽이 k3s로 라우팅. **이 시점부터 compose 기반 동적 프리뷰(`pr-<pr>-app-server` 등) 접근 불가(스펙상 감수).** essence per-PR ingress는 k3s에서 exact-host 매칭으로 계속 동작.

- [ ] **Step 1: SNI map 수정**

`nginx/nginx.conf`의 map 블록에서 `.dev.biyard.co            k3s_ingress;` 아래에 추가:

```nginx
        # *.pr.biyard.co previews are k3s-hosted (pr-webroot wildcard ingress;
        # per-PR full-stack releases override it with exact-host ingresses).
        .pr.biyard.co             k3s_ingress;
```

:80은 변경 불필요 — asset-pr.conf의 기존 :80 리다이렉트 블록이 그대로 동작한다.

- [ ] **Step 2: 사전 검증 후 재시작 (nginx.conf는 단일 파일 마운트 — reload 불가)**

```bash
cd /Users/hackartist/data/devel/github.com/hackartists/local-infra
command docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/certbot/etc:/etc/letsencrypt:ro" \
  -v "$PWD/certbot/var:/var/lib/letsencrypt" \
  -v "$PWD/certbot/webroot:/var/www/certbot:ro" \
  -v "$PWD/nginx/webroot:/var/www/pr:ro" \
  --network biyard-dev nginx:alpine nginx -t
command docker restart nginx
sleep 3 && command docker exec nginx nginx -t
```

Expected: 두 번 다 `test is successful`. 사전 검증 실패 시 restart 금지.

- [ ] **Step 3: 공인 경로 검증 + 회귀**

```bash
SAMPLE=$(ls nginx/webroot | grep -E '^[a-z0-9]+-[0-9]+$' | head -1)
curl -s -o /dev/null -w "$SAMPLE: %{http_code}\n" https://$SAMPLE.pr.biyard.co/
curl -sv https://$SAMPLE.pr.biyard.co/ -o /dev/null 2>&1 | grep "subject:"
for h in s3.miner.biyard.co s3.dev.biyard.co essence.miner.biyard.co n8n.hackartist.io; do
  echo "$h: $(curl -sk -o /dev/null -w '%{http_code}' -I https://$h/)"
done
```

Expected: SAMPLE 200 + `CN=*.pr.biyard.co`(LE), 회귀 4종 정상(200/30x). DNS 네거티브 캐시로 000이면 `--resolve <host>:443:121.131.101.30`으로 재확인.

- [ ] **Step 4: Commit**

```bash
command git add nginx/nginx.conf
command git commit -m "feat(nginx): route *.pr.biyard.co to k3s ingress via SNI passthrough"
```

(miner.conf의 무관한 uncommitted 변경이 섞이지 않게 nginx.conf만 스테이징. nginx.conf 자체에 무관한 uncommitted 변경이 있으면 해당 hunk 제외하고 `git apply --cached`로 내 변경만 스테이징.)

---

### Task 8: compose 러너 제거 + 워크플로우 가이드 + 최종 회귀

**Files:**
- Modify: `docker-compose.yml` (runner1~9 서비스 블록 삭제)
- Create: `k8s/README-runners.md`

**Interfaces:**
- Consumes: Task 6 완료 상태(k3s 러너 가동 중)
- Produces: compose에서 러너 소멸(컨테이너 제거). `runners/` 디렉토리·`nginx/webroot` 원본은 보존.

- [ ] **Step 1: docker-compose.yml에서 runner1~9 블록 삭제**

`runner1`~`runner9` 서비스 블록(각각의 kubeconfig/SSH 마운트 포함) 9개를 삭제. 다른 서비스는 건드리지 않는다.

```bash
command docker compose config --services | grep -c runner || echo "0 (good)"
command docker compose up -d --remove-orphans
command docker ps --format '{{.Names}}' | sort
```

Expected: services에 runner 없음, 기존 runner 컨테이너 소멸, nginx/certbot 등 나머지 정상.

- [ ] **Step 2: `k8s/README-runners.md` 작성**

```markdown
# k3s Actions 러너 & 워크플로우 마이그레이션 가이드

runner1~9는 k3s `infra` 네임스페이스의 StatefulSet `runner`(파드 runner-0~8,
lima-k3s-server 고정)로 이관됐다. 라벨(`linux,arm64,docker`)과 이름은 그대로다.
**docker 데몬은 없다** — docker/compose를 쓰던 잡은 아래 계약으로 전환한다.

## 이미지 빌드 (docker build/push 대체)

러너 파드에는 `buildctl`이 있고 `BUILDKIT_HOST=tcp://buildkitd.infra.svc.cluster.local:1234`가
설정돼 있다:

    buildctl build \
      --frontend dockerfile.v0 --local context=. --local dockerfile=. \
      --output type=image,name=registry.infra.svc.cluster.local:5000/<repo>:<tag>,push=true,registry.insecure=true

- push 이름은 클러스터 내부 주소(무인증 http). k8s 매니페스트에서는 같은 이미지를
  `registry.dev.biyard.co/<repo>:<tag>`로 참조한다(노드 registries.yaml 미러가 처리).
- 캐시: `--export-cache type=registry,ref=registry.infra.svc.cluster.local:5000/<repo>:cache,mode=max,registry.insecure=true`
  `--import-cache type=registry,ref=registry.infra.svc.cluster.local:5000/<repo>:cache,registry.insecure=true`
- 클러스터 밖(개발자 Mac 등)에서는 `buildctl --addr tcp://192.168.0.54:31234 ...`.

## k8s 배포 (compose 프리뷰 대체)

러너 파드의 `kubectl`/`helm`은 ServiceAccount(현재 cluster-admin)로 바로 동작한다.
`~/.kube/config`도 entrypoint가 만들어 두므로 기존 스크립트 호환.
essence의 k3s-preview 패턴(helm release `essence-pr-<pr>`, exact-host ingress
`essence-<pr>.pr.biyard.co`)을 참고 — exact-host ingress는 pr-webroot의
`*.pr.biyard.co` wildcard보다 우선 매칭된다.

## PR 정적 프리뷰

구 `nginx/webroot`(= `/root/nginx` 마운트)는 이제 k3s PVC `pr-webroot`다.
잡이 `/root/nginx/<svc>-<pr>/`에 쓰면 `https://<svc>-<pr>.pr.biyard.co`가
즉시 서빙한다(정적 SPA + `/api`→prod 프록시, `asset-report-<pr>`도 동일).
compose 기반 full-stack e2e 프리뷰(`pr-<pr>-app-server`)는 폐기 —
k3s 배포로 재작성한다.

## 운영

- 스케일: `kubectl -n infra scale sts runner --replicas=<n>` (+ charts/runners/values.yaml 갱신)
- 재등록이 필요할 때: 해당 PVC의 `.runner`/`.credentials*` 삭제 후 파드에
  `RUNNER_TOKEN` env를 임시 주입해 재기동
- 롤백: sts 0으로 축소 → `docker-compose.yml`의 러너 블록 git revert → `docker compose up -d`
  (`runners/` 원본 상태가 보존돼 있어 재등록 불필요)
```

- [ ] **Step 3: 최종 회귀 검증**

```bash
kubectl -n infra get pods | grep -E "runner|buildkitd|pr-nginx|registry" | grep -cv Running || echo "all running"
for i in 0 4 8; do kubectl -n infra logs runner-$i --tail=1 | head -1; done
for h in s3.miner.biyard.co qdrant.dev.biyard.co n8n.hackartist.io essence.miner.biyard.co; do
  echo "$h: $(curl -sk -o /dev/null -w '%{http_code}' -I https://$h/)"
done
```

Expected: 관련 파드 전부 Running, 러너 로그 정상, 회귀 호스트 응답.

- [ ] **Step 4: Commit**

```bash
command git add docker-compose.yml k8s/README-runners.md
command git commit -m "feat: retire compose runners, now on k3s (see k8s/README-runners.md)"
```

---

## Self-Review 결과

- 스펙 커버리지: §3.2→Task 4, §3.3→Task 5(+6), §3.4→Task 2, §3.5→Task 1, §3.6→Task 3(+7 SNI), §3.7 컷오버→Task 6~8 순서, §3.8 롤백→README(Task 8)·compose stop-not-rm(Task 6). §5 산출물 1~8 전부 태스크에 대응.
- 이름 일관성: PVC `state-runner-<N>`(Task 5 volumeClaimTemplates `state` + sts `runner` = `state-runner-N`, Task 6 스크립트 동일), 이미지 `registry.dev.biyard.co/infra/runner:v1`(Task 4 push=내부 이름/Task 5 pull 이름), `pr-biyard-co-tls`(Task 3), buildkitd 주소(Task 2 계약 = Task 4 사용 = README) 교차 확인.
- 주의 명시: k3s 재시작 순단(Task 1), readOnly 마운트 폴백(Task 3), values replicas 0→9 동기화(Task 6), nginx 단일 파일 마운트 재시작 절차(Task 7).

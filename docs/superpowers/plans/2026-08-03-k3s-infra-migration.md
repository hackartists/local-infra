# k3s 인프라 마이그레이션 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** docker-compose의 minio/postgres(+adminer)/qdrant/redpanda(+console)를 k3s `infra` 네임스페이스로 이관하고, 웹 UI 4종의 TLS/ingress를 cert-manager 기반 k3s ingress로 옮긴 뒤 compose에서 해당 서비스를 제거한다.

**Architecture:** 공식 Helm 차트(minio/qdrant/redpanda) + 소형 자체 차트(pg-stack, minio-init, tls)를 `k8s/` 디렉토리에서 helmfile로 통합 관리. 스테이트풀 워크로드는 전부 `lima-k3s-server` 노드에 고정(local-path PVC, 빈 데이터). Mac nginx는 stream SNI 패스스루로 이관 4개 호스트만 k3s ingress(192.168.0.54:443)로 전달.

**Tech Stack:** k3s v1.36.2 (arm64), Helm v4, helmfile, ingress-nginx(hostNetwork, 기설치), cert-manager(Route53 DNS-01), local-path StorageClass

**Spec:** `docs/superpowers/specs/2026-08-03-k3s-infra-migration-design.md`

## Global Constraints

- 네임스페이스: `infra` (기존 존재). cert-manager만 `cert-manager` 네임스페이스.
- 모든 스테이트풀 워크로드: `nodeSelector: {kubernetes.io/hostname: lima-k3s-server}`, StorageClass `local-path`.
- 기존 데이터 이관 없음 — 빈 볼륨으로 시작. Mac의 `./infra/*` 디렉토리는 삭제 금지.
- 자격증명(minioadmin, asset/asset)은 로컬 개발용 평문 values 허용. 단 **AWS Route53 키는 절대 레포에 커밋 금지** — 사용자 수동 Secret 생성.
- Task 8 완료 전까지 docker-compose 스택을 내리지 않는다. Task 9(compose 제거)는 사용자 확인 후에만 진행.
- 이 셸의 zsh에는 깨진 `git` 래퍼 함수가 있음 — 모든 git 명령은 `command git ...`으로 실행할 것.
- 이관 후 내부 접속 주소(소비자 이관 가이드용): `postgres.infra.svc.cluster.local:5432`, `minio.infra.svc.cluster.local:9000`, `qdrant.infra.svc.cluster.local:6333`, redpanda는 Task 5에서 실측 후 README에 기록.
- 공식 차트의 value 키 이름은 차트 버전에 따라 다를 수 있음 — 각 태스크의 "values 키 검증" 단계(`helm show values`)를 건너뛰지 말 것. 불일치 시 해당 차트 문서에 맞춰 values 파일을 수정한 뒤 진행.

---

### Task 1: k8s 스캐폴드 + helmfile 셋업

**Files:**
- Create: `k8s/helmfile.yaml`
- Create: `k8s/.gitignore`

**Interfaces:**
- Produces: `k8s/helmfile.yaml` — 이후 태스크가 release를 추가해 나가는 단일 배포 선언 파일. 이 시점에는 repository 선언만 있고 release는 비어 있음.

- [ ] **Step 1: helmfile 설치 확인/설치**

```bash
helmfile --version || brew install helmfile
```

Expected: 버전 출력. helm v4와의 호환 오류가 뜨면 `brew upgrade helmfile` 후 재시도. 그래도 실패하면 사용자에게 보고 (fallback: 각 태스크의 helmfile 명령을 `helm upgrade --install -n infra <release> <chart> -f <values>`로 대체).

- [ ] **Step 2: 디렉토리 및 helmfile.yaml 생성**

`k8s/helmfile.yaml`:

```yaml
# Local dev infra on k3s. Deploy everything with: helmfile -f k8s/helmfile.yaml apply
repositories:
  - name: minio
    url: https://charts.min.io/
  - name: qdrant
    url: https://qdrant.github.io/qdrant-helm
  - name: redpanda
    url: https://charts.redpanda.com
  - name: jetstack
    url: https://charts.jetstack.io

releases: []
```

`k8s/.gitignore`:

```
charts/**/charts/
*.tgz
```

- [ ] **Step 3: 문법 검증**

```bash
cd k8s && helmfile deps && helmfile list
```

Expected: 에러 없이 빈 release 목록 출력.

- [ ] **Step 4: Commit**

```bash
command git add k8s/helmfile.yaml k8s/.gitignore
command git commit -m "feat(k8s): scaffold helmfile for infra migration"
```

---

### Task 2: pg-stack 자체 차트 (postgres + adminer)

**Files:**
- Create: `k8s/charts/pg-stack/Chart.yaml`
- Create: `k8s/charts/pg-stack/values.yaml`
- Create: `k8s/charts/pg-stack/templates/postgres.yaml`
- Create: `k8s/charts/pg-stack/templates/adminer.yaml`
- Modify: `k8s/helmfile.yaml` (release 추가)

**Interfaces:**
- Produces: Service `postgres`(ClusterIP :5432), Service `postgres-nodeport`(NodePort 30432), Service `adminer`(:8080). Task 7이 `adminer` svc로 ingress를 붙이고, Task 6의 TLS secret 이름 `miner-biyard-co-tls`를 values 기본값으로 미리 참조한다(ingress는 기본 disabled).

- [ ] **Step 1: Chart.yaml / values.yaml 작성**

`k8s/charts/pg-stack/Chart.yaml`:

```yaml
apiVersion: v2
name: pg-stack
description: Postgres + Adminer for local dev (mirrors compose postgres/pgweb)
type: application
version: 0.1.0
appVersion: "16"
```

`k8s/charts/pg-stack/values.yaml`:

```yaml
nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

postgres:
  image: postgres:16-alpine
  user: asset
  password: asset
  db: asset
  storage: 20Gi
  storageClass: local-path
  nodePort: 30432

adminer:
  image: adminer:latest
  ingress:
    enabled: false
    host: pg.miner.biyard.co
    className: nginx
    tlsSecret: miner-biyard-co-tls
```

- [ ] **Step 2: postgres 템플릿 작성**

`k8s/charts/pg-stack/templates/postgres.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      containers:
        - name: postgres
          image: {{ .Values.postgres.image }}
          ports:
            - containerPort: 5432
              name: pg
          env:
            - name: POSTGRES_USER
              value: {{ .Values.postgres.user | quote }}
            - name: POSTGRES_PASSWORD
              value: {{ .Values.postgres.password | quote }}
            - name: POSTGRES_DB
              value: {{ .Values.postgres.db | quote }}
            # local-path provisions a plain dir; initdb wants an empty subdir
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", {{ .Values.postgres.user | quote }}, "-d", {{ .Values.postgres.db | quote }}]
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.postgres.storageClass }}
        resources:
          requests:
            storage: {{ .Values.postgres.storage }}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
---
# Host access for `make test-pg` style workflows (cargo runs on the Mac)
apiVersion: v1
kind: Service
metadata:
  name: postgres-nodeport
spec:
  type: NodePort
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: {{ .Values.postgres.nodePort }}
```

- [ ] **Step 3: adminer 템플릿 작성**

`k8s/charts/pg-stack/templates/adminer.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminer
  template:
    metadata:
      labels:
        app: adminer
    spec:
      containers:
        - name: adminer
          image: {{ .Values.adminer.image }}
          ports:
            - containerPort: 8080
          env:
            - name: ADMINER_DEFAULT_SERVER
              value: postgres
---
apiVersion: v1
kind: Service
metadata:
  name: adminer
spec:
  selector:
    app: adminer
  ports:
    - port: 8080
      targetPort: 8080
{{- if .Values.adminer.ingress.enabled }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: adminer
spec:
  ingressClassName: {{ .Values.adminer.ingress.className }}
  tls:
    - hosts: [{{ .Values.adminer.ingress.host | quote }}]
      secretName: {{ .Values.adminer.ingress.tlsSecret }}
  rules:
    - host: {{ .Values.adminer.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: adminer
                port:
                  number: 8080
{{- end }}
```

- [ ] **Step 4: helmfile에 release 추가**

`k8s/helmfile.yaml`의 `releases: []`를 다음으로 교체:

```yaml
releases:
  - name: pg-stack
    namespace: infra
    chart: ./charts/pg-stack
```

- [ ] **Step 5: 렌더링 검증 후 배포**

```bash
cd k8s && helm template pg-stack ./charts/pg-stack >/dev/null && helmfile -l name=pg-stack apply
```

Expected: 렌더 에러 없음, release 배포 성공.

- [ ] **Step 6: 동작 검증**

```bash
kubectl -n infra rollout status statefulset/postgres --timeout=180s
kubectl -n infra get pod -l app=postgres -o wide   # NODE가 lima-k3s-server인지 확인
psql "host=192.168.0.54 port=30432 user=asset password=asset dbname=asset" -c 'select 1' \
  || kubectl -n infra exec postgres-0 -- psql -U asset -d asset -c 'select 1'
kubectl -n infra get pod -l app=adminer   # Running 확인
```

Expected: `select 1` → `1`. (호스트에 psql 없으면 exec fallback 사용, NodePort는 `nc -vz 192.168.0.54 30432`로 확인.)

- [ ] **Step 7: Commit**

```bash
command git add k8s/charts/pg-stack k8s/helmfile.yaml
command git commit -m "feat(k8s): pg-stack chart (postgres + adminer) on lima node"
```

---

### Task 3: minio (공식 차트) + minio-init Job

**Files:**
- Create: `k8s/values/minio.yaml`
- Create: `k8s/charts/minio-init/Chart.yaml`
- Create: `k8s/charts/minio-init/values.yaml`
- Create: `k8s/charts/minio-init/templates/job.yaml`
- Modify: `k8s/helmfile.yaml` (release 2개 추가)

**Interfaces:**
- Consumes: 없음 (독립)
- Produces: Service `minio`(:9000 API), Service `minio-console`(:9001). 버킷 `assets-local-uploads`, `assets-local-doc-converter-temp`(1일 만료 ilm). Task 7이 `s3.miner.biyard.co` consoleIngress를 values로 켠다.

- [ ] **Step 1: values 키 검증**

```bash
helm repo add minio https://charts.min.io/ 2>/dev/null; helm repo update minio
helm show values minio/minio | grep -nE "rootUser|rootPassword|^mode|consoleIngress|nodeSelector|persistence" | head -30
```

Expected: 아래 Step 2에서 쓰는 키들이 존재. 이름이 다르면 values 파일을 실제 키에 맞게 수정.

- [ ] **Step 2: `k8s/values/minio.yaml` 작성**

```yaml
mode: standalone
replicas: 1

rootUser: minioadmin
rootPassword: minioadmin

persistence:
  enabled: true
  storageClass: local-path
  size: 100Gi

nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

resources:
  requests:
    memory: 512Mi

environment:
  MINIO_BROWSER_REDIRECT_URL: https://s3.miner.biyard.co

# Ingress는 Task 7에서 활성화
consoleIngress:
  enabled: false
```

- [ ] **Step 3: minio-init 차트 작성 (compose의 minio-init 미러)**

`k8s/charts/minio-init/Chart.yaml`:

```yaml
apiVersion: v2
name: minio-init
description: One-shot bucket + ilm provisioning (mirrors compose minio-init)
type: application
version: 0.1.0
appVersion: "1"
```

`k8s/charts/minio-init/values.yaml`:

```yaml
image: minio/mc:latest
endpoint: http://minio:9000
accessKey: minioadmin
secretKey: minioadmin
```

`k8s/charts/minio-init/templates/job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-init
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 20
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: {{ .Values.image }}
          command: ["/bin/sh", "-c"]
          args:
            - >
              mc alias set local {{ .Values.endpoint }} {{ .Values.accessKey }} {{ .Values.secretKey }} &&
              mc mb -p local/assets-local-uploads &&
              mc mb -p local/assets-local-doc-converter-temp &&
              (mc ilm rule add --expire-days 1 local/assets-local-doc-converter-temp || true)
```

- [ ] **Step 4: helmfile에 release 추가**

`k8s/helmfile.yaml`의 `releases:` 하위에 추가:

```yaml
  - name: minio
    namespace: infra
    chart: minio/minio
    values:
      - values/minio.yaml
  - name: minio-init
    namespace: infra
    chart: ./charts/minio-init
    needs:
      - infra/minio
```

- [ ] **Step 5: 배포**

```bash
cd k8s && helmfile -l name=minio -l name=minio-init apply
```

Expected: minio pod Running(lima 노드), minio-init Job Completed.

- [ ] **Step 6: 동작 검증**

```bash
kubectl -n infra get pods -l release=minio -o wide
kubectl -n infra wait --for=condition=complete job/minio-init --timeout=180s
kubectl -n infra run mc-smoke --rm -i --restart=Never --image=minio/mc:latest --command -- /bin/sh -c \
  "mc alias set local http://minio:9000 minioadmin minioadmin && mc ls local && mc ilm rule ls local/assets-local-doc-converter-temp"
```

Expected: 버킷 2개 목록 출력 + doc-converter-temp에 1일 만료 규칙 존재.

- [ ] **Step 7: Commit**

```bash
command git add k8s/values/minio.yaml k8s/charts/minio-init k8s/helmfile.yaml
command git commit -m "feat(k8s): minio via official chart + bucket/ilm init job"
```

---

### Task 4: qdrant (공식 차트)

**Files:**
- Create: `k8s/values/qdrant.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Produces: Service `qdrant`(:6333 http, :6334 grpc). Task 7이 `qdrant.miner.biyard.co` ingress를 values로 켠다.

- [ ] **Step 1: values 키 검증**

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm 2>/dev/null; helm repo update qdrant
helm show values qdrant/qdrant | grep -nE "replicaCount|persistence|storage|ingress|nodeSelector|apiKey" | head -30
```

- [ ] **Step 2: `k8s/values/qdrant.yaml` 작성**

```yaml
replicaCount: 1

nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

persistence:
  size: 20Gi
  storageClassName: local-path

# Ingress는 Task 7에서 활성화
ingress:
  enabled: false
```

- [ ] **Step 3: helmfile release 추가 및 배포**

`k8s/helmfile.yaml` `releases:`에 추가:

```yaml
  - name: qdrant
    namespace: infra
    chart: qdrant/qdrant
    values:
      - values/qdrant.yaml
```

```bash
cd k8s && helmfile -l name=qdrant apply
```

- [ ] **Step 4: 동작 검증**

```bash
kubectl -n infra rollout status statefulset/qdrant --timeout=180s
kubectl -n infra run qdrant-smoke --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sf http://qdrant:6333/collections
```

Expected: `{"result":{"collections":[]},...}` 형태의 200 응답.

- [ ] **Step 5: Commit**

```bash
command git add k8s/values/qdrant.yaml k8s/helmfile.yaml
command git commit -m "feat(k8s): qdrant via official chart"
```

---

### Task 5: redpanda + console (공식 차트)

**Files:**
- Create: `k8s/values/redpanda.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Produces: 내부 Kafka 부트스트랩 주소(Step 5에서 실측, 예상 `redpanda-0.redpanda.infra.svc.cluster.local:9093`), console Service. Task 7이 console ingress를 켜고, Task 9가 실측 주소를 README에 기록.

- [ ] **Step 1: values 키 검증**

```bash
helm repo add redpanda https://charts.redpanda.com 2>/dev/null; helm repo update redpanda
helm show values redpanda/redpanda | grep -nE "statefulset|replicas|tls|external|storage|resources|console|auto_create" | head -40
```

주의: redpanda 차트는 버전에 따라 `tls.enabled=false` 외에 listener별 tls 설정이 필요할 수 있음. `helm show values`에서 `listeners` 구조를 확인하고 TLS가 전부 꺼지도록 맞출 것.

- [ ] **Step 2: `k8s/values/redpanda.yaml` 작성**

```yaml
statefulset:
  replicas: 1
  additionalRedpandaCmdFlags:
    - --overprovisioned
    - --smp=1

nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

tls:
  enabled: false

external:
  enabled: false

resources:
  cpu:
    cores: 1
  memory:
    container:
      max: 1.5Gi

storage:
  persistentVolume:
    enabled: true
    size: 20Gi
    storageClass: local-path

config:
  cluster:
    auto_create_topics_enabled: true

console:
  enabled: true
  # console ingress는 Task 7에서 활성화
```

- [ ] **Step 3: helmfile release 추가 및 배포**

`k8s/helmfile.yaml` `releases:`에 추가:

```yaml
  - name: redpanda
    namespace: infra
    chart: redpanda/redpanda
    values:
      - values/redpanda.yaml
```

```bash
cd k8s && helmfile -l name=redpanda apply
```

Expected: `redpanda-0` pod Running + console pod Running. 배포가 chart 복잡도(TLS 요구, sidecar 등)로 계속 실패하면 **폴백**: 스펙 §3.6에 따라 pg-stack 스타일의 자체 StatefulSet 차트(`k8s/charts/redpanda-lite/`, compose와 동일한 `redpandadata/redpanda` 이미지 + 동일 커맨드라인 + `redpandadata/console` Deployment)로 전환하고 사용자에게 보고.

- [ ] **Step 4: produce/consume 스모크 테스트**

```bash
kubectl -n infra exec redpanda-0 -c redpanda -- rpk cluster info
kubectl -n infra exec redpanda-0 -c redpanda -- /bin/sh -c 'echo smoke-msg | rpk topic produce smoke-test'
kubectl -n infra exec redpanda-0 -c redpanda -- rpk topic consume smoke-test --num 1
kubectl -n infra exec redpanda-0 -c redpanda -- rpk topic delete smoke-test
```

Expected: cluster info에 브로커 1개, consume에서 `smoke-msg` 확인.

- [ ] **Step 5: 내부 부트스트랩 주소 실측 (README용 기록)**

```bash
kubectl -n infra get svc | grep -i redpanda
kubectl -n infra exec redpanda-0 -c redpanda -- rpk cluster info | grep -A3 -i broker
```

실측된 `<host>:<port>`를 Task 9의 README 표에 그대로 기입한다.

- [ ] **Step 6: Commit**

```bash
command git add k8s/values/redpanda.yaml k8s/helmfile.yaml
command git commit -m "feat(k8s): redpanda + console via official chart (single node, no TLS)"
```

---

### Task 6: cert-manager + Route53 DNS-01 와일드카드 인증서

**Files:**
- Create: `k8s/values/cert-manager.yaml`
- Create: `k8s/charts/tls/Chart.yaml`
- Create: `k8s/charts/tls/values.yaml`
- Create: `k8s/charts/tls/templates/cluster-issuer.yaml`
- Create: `k8s/charts/tls/templates/certificate.yaml`
- Modify: `k8s/helmfile.yaml`

**Interfaces:**
- Consumes: 사용자가 수동 생성하는 Secret `route53-credentials`(cert-manager 네임스페이스, key: `access-key-id`, `secret-access-key`)
- Produces: `infra` 네임스페이스 TLS Secret **`miner-biyard-co-tls`** (`*.miner.biyard.co` 와일드카드). Task 7의 모든 ingress가 이 secret 이름을 사용.

- [ ] **Step 1: 사용자에게 Route53 자격증명 요청 (블로킹)**

사용자에게 다음을 안내하고 완료 응답을 기다린다. 필요 IAM 권한: `route53:GetChange`, `route53:ChangeResourceRecordSets`, `route53:ListHostedZonesByName`.

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cert-manager create secret generic route53-credentials \
  --from-literal=access-key-id='AKIA...' \
  --from-literal=secret-access-key='...'
```

**이 값은 절대 레포/로그에 남기지 않는다. Secret 생성은 사용자가 직접 실행한다.**

- [ ] **Step 2: cert-manager values 작성**

`k8s/values/cert-manager.yaml`:

```yaml
crds:
  enabled: true
```

(설치 후 `kubectl get crd certificates.cert-manager.io`가 없으면 구버전 차트임 — `installCRDs: true`로 바꿔 재시도.)

- [ ] **Step 3: tls 차트 작성**

`k8s/charts/tls/Chart.yaml`:

```yaml
apiVersion: v2
name: tls
description: ClusterIssuer (Route53 DNS-01) + wildcard cert for *.miner.biyard.co
type: application
version: 0.1.0
appVersion: "1"
```

`k8s/charts/tls/values.yaml`:

```yaml
email: admin@biyard.co
acmeServer: https://acme-v02.api.letsencrypt.org/directory
awsRegion: ap-northeast-2
credentialsSecret: route53-credentials
dnsZone: miner.biyard.co
certSecretName: miner-biyard-co-tls
```

`k8s/charts/tls/templates/cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-route53
spec:
  acme:
    email: {{ .Values.email }}
    server: {{ .Values.acmeServer }}
    privateKeySecretRef:
      name: letsencrypt-route53-account
    solvers:
      - selector:
          dnsZones:
            - {{ .Values.dnsZone | quote }}
        dns01:
          route53:
            region: {{ .Values.awsRegion }}
            accessKeyIDSecretRef:
              name: {{ .Values.credentialsSecret }}
              key: access-key-id
            secretAccessKeySecretRef:
              name: {{ .Values.credentialsSecret }}
              key: secret-access-key
```

`k8s/charts/tls/templates/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: miner-biyard-co
spec:
  secretName: {{ .Values.certSecretName }}
  dnsNames:
    - "*.{{ .Values.dnsZone }}"
  issuerRef:
    name: letsencrypt-route53
    kind: ClusterIssuer
```

- [ ] **Step 4: helmfile release 추가 및 배포**

`k8s/helmfile.yaml` `releases:`에 추가:

```yaml
  - name: cert-manager
    namespace: cert-manager
    chart: jetstack/cert-manager
    values:
      - values/cert-manager.yaml
  - name: tls
    namespace: infra
    chart: ./charts/tls
    needs:
      - cert-manager/cert-manager
```

```bash
cd k8s && helmfile -l name=cert-manager -l name=tls apply
```

- [ ] **Step 5: 발급 검증**

```bash
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n infra wait --for=condition=Ready certificate/miner-biyard-co --timeout=600s
kubectl -n infra get secret miner-biyard-co-tls
```

Expected: Certificate Ready=True, secret 존재. 실패 시 `kubectl -n infra describe certificate miner-biyard-co` 와 `kubectl -n cert-manager logs deploy/cert-manager | tail -30`으로 원인 확인 (대부분 IAM 권한 또는 리전/존 문제).

- [ ] **Step 6: Commit**

```bash
command git add k8s/values/cert-manager.yaml k8s/charts/tls k8s/helmfile.yaml
command git commit -m "feat(k8s): cert-manager + route53 dns-01 wildcard cert for miner.biyard.co"
```

---

### Task 7: 웹 UI 4종 Ingress 활성화

**Files:**
- Modify: `k8s/values/minio.yaml` (consoleIngress)
- Modify: `k8s/values/qdrant.yaml` (ingress)
- Modify: `k8s/values/redpanda.yaml` (console.ingress)
- Modify: `k8s/charts/pg-stack/values.yaml` (adminer.ingress.enabled)

**Interfaces:**
- Consumes: Task 6의 Secret `miner-biyard-co-tls`, Task 2~5의 Service들
- Produces: Ingress 4개 — `s3.|pg.|redpanda.|qdrant.miner.biyard.co`. Task 8이 이 호스트들을 SNI 패스스루로 라우팅.

- [ ] **Step 1: minio consoleIngress 활성화**

`k8s/values/minio.yaml`의 `consoleIngress:` 블록을 교체:

```yaml
consoleIngress:
  enabled: true
  ingressClassName: nginx
  path: /
  hosts:
    - s3.miner.biyard.co
  tls:
    - secretName: miner-biyard-co-tls
      hosts:
        - s3.miner.biyard.co
```

- [ ] **Step 2: qdrant ingress 활성화**

`k8s/values/qdrant.yaml`의 `ingress:` 블록을 교체 (키 구조는 Task 4 Step 1의 `helm show values` 결과에 맞춤):

```yaml
ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    # 기존 nginx의 "/ → /dashboard" 리다이렉트 유지
    nginx.ingress.kubernetes.io/app-root: /dashboard
  hosts:
    - host: qdrant.miner.biyard.co
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: miner-biyard-co-tls
      hosts:
        - qdrant.miner.biyard.co
```

- [ ] **Step 3: redpanda console ingress 활성화**

`k8s/values/redpanda.yaml`의 `console:` 블록을 교체 (키 구조는 `helm show values redpanda/redpanda`의 console 섹션에 맞춤):

```yaml
console:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: redpanda.miner.biyard.co
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: miner-biyard-co-tls
        hosts:
          - redpanda.miner.biyard.co
```

- [ ] **Step 4: adminer ingress 활성화**

`k8s/charts/pg-stack/values.yaml`에서 `adminer.ingress.enabled: false` → `true`.

- [ ] **Step 5: 배포 및 검증**

```bash
cd k8s && helmfile apply
kubectl -n infra get ingress
for h in s3 pg redpanda qdrant; do
  curl -skI --resolve $h.miner.biyard.co:443:192.168.0.54 https://$h.miner.biyard.co/ | head -1
done
curl -sv --resolve s3.miner.biyard.co:443:192.168.0.54 https://s3.miner.biyard.co/ -o /dev/null 2>&1 | grep -E "subject|issuer"
```

Expected: ingress 4개 생성, 각 호스트 HTTP 200/30x 응답, 인증서 subject가 `*.miner.biyard.co`(Let's Encrypt 발급, `-k` 없이도 통과해야 정상).

- [ ] **Step 6: Commit**

```bash
command git add k8s/values k8s/charts/pg-stack/values.yaml
command git commit -m "feat(k8s): enable tls ingresses for minio/adminer/redpanda-console/qdrant"
```

---

### Task 8: Mac nginx SNI 패스스루 리팩토링

**Files:**
- Modify: `nginx/nginx.conf` (stream 블록 추가)
- Modify: `nginx/conf.d/*.conf` (모든 `listen 443 ssl` → `listen 8443 ssl`)

**Interfaces:**
- Consumes: Task 7의 ingress 4개 (192.168.0.54:443)
- Produces: 공인 :443 트래픽의 SNI 분기 — 이관 4개 호스트는 k3s로, 나머지 전 vhost는 로컬 :8443으로. **이 태스크부터 웹 UI 4종은 k3s가 서빙한다 (compose 서비스는 아직 유지).**

- [ ] **Step 1: nginx stream 모듈 확인**

```bash
docker exec nginx nginx -V 2>&1 | tr ' ' '\n' | grep -E "with-stream"
```

Expected: `--with-stream` 및 `--with-stream_ssl_preread_module` 존재. (없으면 사용자 보고 — nginx 이미지 교체 필요.)

- [ ] **Step 2: `nginx/nginx.conf`에 stream 블록 추가**

전체 파일을 다음으로 교체:

```nginx
events {
    worker_connections 1024;
}

# SNI-based L4 split: infra hosts migrated to k3s get raw TLS passthrough
# (cert-manager terminates TLS in-cluster); every other vhost keeps being
# served locally and now listens on 8443 behind this stream proxy.
stream {
    map $ssl_preread_server_name $tls_backend {
        s3.miner.biyard.co        k3s_ingress;
        pg.miner.biyard.co        k3s_ingress;
        redpanda.miner.biyard.co  k3s_ingress;
        qdrant.miner.biyard.co    k3s_ingress;
        default                   local_vhosts;
    }

    upstream k3s_ingress {
        server 192.168.0.54:443;
    }

    upstream local_vhosts {
        server 127.0.0.1:8443;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $tls_backend;
    }
}

http {
    # Map file extensions to Content-Type. Without this, nginx's built-in
    # default map only covers html/gif/jpg, so .css/.js fall through to
    # default_type (text/plain) — which makes browsers refuse stylesheets and
    # block ES module scripts ("Expected a JavaScript module script but ...
    # MIME type of text/plain"). Required for the per-PR static previews.
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
}
```

- [ ] **Step 3: conf.d 전체의 443 리슨을 8443으로 이동**

```bash
cd nginx/conf.d && sed -i '' 's/listen 443 ssl;/listen 8443 ssl;/' *.conf && grep -rn "listen 443" *.conf
```

Expected: grep 결과 없음 (443 리슨은 이제 stream만 소유). 대상 파일: `miner.conf`, `infra.conf`, `asset-pr.conf`, `n8n.conf`, `summer.conf`, `ratel-html.conf`. `:80` 서버 블록(HTTPS 리다이렉트/ACME)은 변경하지 않는다 — 이관 호스트도 redirect가 stream을 거쳐 k3s로 가므로 동작 동일.

주의: `miner.conf`는 이 작업 전부터 uncommitted 변경이 있음(`M nginx/conf.d/miner.conf`). sed 적용은 무방하나 커밋 시 기존 변경분이 섞이지 않게 hunk 단위로 확인할 것.

- [ ] **Step 4: 문법 검증 및 reload**

```bash
docker exec nginx nginx -t && docker exec nginx nginx -s reload
```

Expected: `syntax is ok` / `test is successful`. 실패 시 reload 하지 말고 원인 수정.

- [ ] **Step 5: 이관 호스트 + 회귀 검증**

```bash
# 이관 4종: k3s 인증서(Let's Encrypt, *.miner.biyard.co)로 서빙되는지
for h in s3 pg redpanda qdrant; do
  echo "== $h =="; curl -sI https://$h.miner.biyard.co/ | head -1
done
# 회귀: 기존 vhost가 여전히 로컬(:8443 경유)로 서빙되는지
for h in asset.miner.biyard.co essence.miner.biyard.co n8n.hackartist.io summer.biyard.co; do
  echo "== $h =="; curl -skI https://$h/ | head -1
done
```

Expected: 8개 호스트 모두 200/30x. 이관 4종은 `curl -v`로 인증서 발급자가 Let's Encrypt(R 계열)인지 확인. 회귀 호스트 중 하나라도 실패하면 즉시 원인 수정(필요 시 `command git checkout -- nginx/` + reload로 롤백).

- [ ] **Step 6: Commit**

```bash
command git add nginx/nginx.conf nginx/conf.d
command git commit -m "refactor(nginx): SNI passthrough to k3s ingress for migrated infra hosts"
```

(`miner.conf`에 무관한 기존 변경이 섞여 있으면 해당 hunk 제외하고 커밋.)

---

### Task 9: compose 정리 + README (사용자 확인 후 진행)

**Files:**
- Modify: `docker-compose.yml` (minio, minio-init, postgres, pgweb, qdrant, redpanda, redpanda-console 제거)
- Modify: `nginx/conf.d/infra.conf` (s3/pg/redpanda/qdrant의 `listen 8443 ssl` 블록 제거, ollama 블록과 4개 호스트의 `:80` 블록은 유지)
- Create: `k8s/README.md`

**Interfaces:**
- Consumes: Task 5 Step 5에서 실측한 redpanda 부트스트랩 주소
- Produces: compose에서 데이터 인프라 제거 완료. 소비자 이관 가이드(README).

- [ ] **Step 1: 사용자 확인 (블로킹)**

Task 8까지의 검증 결과를 요약 보고하고, compose 서비스 제거 진행 여부를 사용자에게 확인받는다. 승인 전 진행 금지.

- [ ] **Step 2: docker-compose.yml에서 7개 서비스 제거**

`minio`, `minio-init`, `postgres`, `pgweb`, `qdrant`, `redpanda`, `redpanda-console` 서비스 블록을 삭제. `ollama`, `open-webui`, `nginx`, `runner*`, `openvpn`, `certbot`, `n8n`은 유지. `./infra/*` 디렉토리는 건드리지 않는다.

- [ ] **Step 3: infra.conf 정리**

`nginx/conf.d/infra.conf`에서 s3/pg/redpanda/qdrant 4개 호스트의 `listen 8443 ssl` 서버 블록만 삭제. 각 호스트의 `:80` 블록(HTTPS 리다이렉트)과 ollama(`ollama.miner.biyard.co` → open-webui) 블록 2개는 유지.

- [ ] **Step 4: 컨테이너 정리 및 검증**

```bash
docker compose up -d --remove-orphans
docker exec nginx nginx -t && docker exec nginx nginx -s reload
docker ps --format '{{.Names}}' | sort
ls infra/   # minio postgres qdrant redpanda 디렉토리가 그대로인지 확인
```

Expected: 제거 대상 7개 컨테이너 소멸, nginx/runner/openvpn/n8n/ollama/open-webui 정상, `infra/` 데이터 보존. Task 8 Step 5의 검증 루프를 한 번 더 돌려 이관/회귀 호스트 전부 정상 확인.

- [ ] **Step 5: `k8s/README.md` 작성**

아래 골격으로 작성하되 `<redpanda-bootstrap>`은 Task 5 Step 5 실측값으로 치환:

```markdown
# k8s local infra

`helmfile -f k8s/helmfile.yaml apply` 한 번으로 전체 배포.
구성: minio, postgres(+adminer), qdrant, redpanda(+console), cert-manager, tls.

## 접속 주소 (구 docker-compose → k3s)

| 용도 | 구 주소 (biyard-dev) | 신 주소 (클러스터 내부) | 호스트에서 |
|---|---|---|---|
| Postgres | postgres:5432 | postgres.infra.svc.cluster.local:5432 | 192.168.0.54:30432 |
| MinIO S3 API | minio:9000 | minio.infra.svc.cluster.local:9000 | (ingress 경유) |
| Qdrant | qdrant:6333 | qdrant.infra.svc.cluster.local:6333 | https://qdrant.miner.biyard.co |
| Kafka | redpanda:9092 | <redpanda-bootstrap> | - |
| MinIO Console | s3.miner.biyard.co | 동일 (k3s ingress 서빙) | https://s3.miner.biyard.co |
| DB Admin | pg.miner.biyard.co | 동일 | https://pg.miner.biyard.co |
| Redpanda Console | redpanda.miner.biyard.co | 동일 | https://redpanda.miner.biyard.co |

## TLS

cert-manager가 Route53 DNS-01로 `*.miner.biyard.co` 와일드카드를 자동 갱신.
AWS 키는 `cert-manager` 네임스페이스의 `route53-credentials` Secret (수동 생성, 레포에 없음).

## 주의

- 모든 스테이트풀 데이터는 lima VM(`lima-k3s-server`)의 local-path PV에 있음.
  **VM을 지우면 데이터도 사라진다.** 구 데이터는 레포의 `infra/`에 보존됨.
- Mac nginx가 :443에서 SNI로 s3/pg/redpanda/qdrant.miner.biyard.co만
  k3s(192.168.0.54:443)로 패스스루하고, 나머지 vhost는 로컬 :8443에서 서빙.
```

- [ ] **Step 6: Commit**

```bash
command git add docker-compose.yml nginx/conf.d/infra.conf k8s/README.md
command git commit -m "feat: retire compose data infra, now served by k3s (see k8s/README.md)"
```

---

## Self-Review 결과

- 스펙 §3.1~§3.4 → Task 1~8, §3.5 전환 순서 → Task 8~9 (병렬 운영 보장: Task 9 이전까지 compose 무변경), §3.6 redpanda 폴백 → Task 5 Step 3, §4 성공 기준 → 각 태스크 검증 단계 + Task 8 Step 5 회귀 루프. §5 스코프 외 항목은 README 안내로만 처리.
- 공식 차트 value 키는 버전 변동 가능성이 있어 각 태스크에 `helm show values` 검증 단계를 명시함 (No-Placeholder 원칙과의 절충: 예상 키를 전부 실제 값으로 기재하되, 검증 단계에서 불일치 시 수정하도록 지시).
- 타입/이름 일관성: TLS secret `miner-biyard-co-tls`(Task 2/6/7), ClusterIssuer `letsencrypt-route53`(Task 6), k3s ingress IP `192.168.0.54`(Task 7/8), NodePort `30432`(Task 2/9) 교차 확인 완료.

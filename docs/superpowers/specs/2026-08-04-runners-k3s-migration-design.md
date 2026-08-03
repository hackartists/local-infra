# GitHub Actions 러너 k3s 마이그레이션 설계

- 날짜: 2026-08-04
- 상태: 사용자 승인됨 (구현 전)
- 선행 작업: 2026-08-03 k3s 인프라 마이그레이션(데이터 서비스·TLS·레지스트리·lima 빌드 VM) 완료 상태를 전제로 한다.

## 1. 배경 / 현재 상태

- **runner1~9**: docker-compose 컨테이너, org 레벨(`https://github.com/biyard`) 등록, 라벨 `linux,arm64,docker`, 이름 `runner1`~`runner9`.
- 이미지: `Dockerfile.runner` — AL2023 + Rust(rustup) + dotnet-sdk-10.0 + docker CLI + compose 플러그인. 러너 바이너리는 entrypoint가 v2.335.1을 다운로드, 최초 1회 `config.sh --url https://github.com/biyard --token $RUNNER_TOKEN`으로 등록 후 상태가 `runners/runnerN/`에 저장(`.runner`, `.credentials`, `.credentials_rsaparams`).
- 마운트 의존성:
  1. `/var/run/docker.sock` — Docker Desktop 데몬 공유 (빌드, compose 실행)
  2. `./runners/runnerN` — 등록 상태 + `_work`
  3. `./nginx/webroot` — PR 정적 프리뷰 파일 (Mac nginx가 `*.pr.biyard.co`로 서빙, `asset-pr.conf`/`ratel-html.conf`)
  4. `~/.kube/config` + lima SSH 키(ro) — essence k3s-preview/pr-cleanup 잡의 클러스터 접근
- k3s: lima-k3s-server(Mac 위 VM, 32vCPU/128GiB) + hackartist-pi(4코어/8GiB). `registry.dev.biyard.co`(ingress basic auth) 및 lima `docker` VM(빌드용, `lima-docker` context) 구축 완료.

## 2. 사용자 결정 사항

| 결정 | 선택 |
|---|---|
| 러너 관리 | 정적 StatefulSet 9개 — 라벨(`linux,arm64,docker`)·이름 유지, 전 레포 runs-on 무수정 |
| docker | **완전 제거** — 빌드는 buildkit(→registry push), compose 의존 워크플로우는 k3s 배포로 재작성 |
| PR 정적 프리뷰 | k3s로 이전 (PVC + nginx pod + `*.pr.biyard.co` ingress) |
| 등록 자격증명 | 기존 `runners/runnerN` 상태 디렉토리 이관 (재등록 없음) |
| 전환 방식 | **빅뱅** — 러너 9개를 한 번에 컷오버, docker 의존 잡의 일시적 실패를 감수하고 워크플로우를 사후 마이그레이션 |
| 노드 배치 | **러너·buildkitd 전부 lima-k3s-server 고정** — 빌드 메모리 요구로 Pi 배치 금지 |

## 3. 아키텍처

### 3.1 구성 요소 (신규는 모두 `k8s/` 하위, helmfile 릴리스로 관리, namespace `infra`)

```
k8s/charts/runners/          # StatefulSet runner (replicas 9) + SA/RBAC
k8s/charts/buildkitd/        # 공유 buildkitd Deployment + Service
k8s/charts/pr-webroot/       # PR 정적 프리뷰: PVC + nginx Deployment + ingress
Dockerfile.runner-k8s        # 새 러너 이미지 (레포 루트, 기존 Dockerfile.runner 계승)
```

### 3.2 러너 이미지 (`Dockerfile.runner-k8s`)

- 베이스·툴체인은 기존과 동일(AL2023, rustup, dotnet-sdk-10.0, gcc/cmake/git 등)하되:
  - 제거: docker 패키지, compose 플러그인 (docker 시맨틱 폐기)
  - 추가: `kubectl`, `buildctl`(buildkit 클라이언트), `docker buildx` 독립 바이너리는 불필요 — buildctl로 통일. helm도 추가(프리뷰 배포용).
- 빌드·배포: Mac에서 `docker --context lima-docker build` → `registry.dev.biyard.co/infra/runner:<tag>` push.
- 러너 바이너리는 기존 entrypoint 방식 유지(최초 실행 시 다운로드). entrypoint는 `runner-entrypoint.sh`를 계승하되 이미지에 COPY(호스트 바인드 마운트 제거).

### 3.3 러너 StatefulSet (`k8s/charts/runners/`)

- `StatefulSet runner`, replicas 9, `nodeSelector: lima-k3s-server`, 파드명 `runner-0`~`runner-8`.
- `RUNNER_NAME`은 기존 이름 유지가 필수(등록 상태 이관) → 파드 ordinal과 매핑: `runner-<N>` 파드가 `runnerN+1` 상태를 사용. entrypoint에서 `RUNNER_NAME=runner$((ordinal+1))` 계산.
- volumeClaimTemplates: `state` PVC(local-path, 20Gi/러너) → `/root/runner`. 초기 1회 기존 `runners/runnerN`의 등록 파일(`.runner`, `.credentials`, `.credentials_rsaparams`, `.env`, `.path`)만 이관(스크립트, §5). `_work`·바이너리는 이관하지 않음(재다운로드).
- 클러스터 접근: kubeconfig/SSH 키 마운트를 **ServiceAccount `runner` + RBAC**로 대체.
  - 프리뷰 배포가 임의 네임스페이스 생성·조작을 하므로 초기에는 cluster-admin 바인딩으로 시작하되, 스펙상 후속 축소 항목으로 명시(현행 마운트가 cluster-admin kubeconfig이므로 보안 동등 이상).
  - 파드 안 `kubectl`은 in-cluster 자격증명을 자동 사용 → 워크플로우의 `KUBECONFIG` 의존 제거. (전환기 호환: entrypoint가 in-cluster 토큰으로 `/root/.kube/config`를 생성해 기존 잡 스크립트가 그대로 동작하게 함.)
- 리소스: requests cpu 1/mem 2Gi, limits 없음(lima 32vCPU/128GiB 공유; 러너 잡 피크가 겹쳐도 VM 상한이 방어). PR 프리뷰 PVC 마운트: `pr-webroot` PVC를 `/root/nginx`에 마운트(기존 잡이 쓰던 경로 유지 — compose에서 `./nginx/webroot:/root/nginx`였음).

### 3.4 buildkitd (`k8s/charts/buildkitd/`)

- `Deployment buildkitd`(privileged, 단일 replica, lima 고정) + `Service buildkitd:1234`(tcp listener `--addr tcp://0.0.0.0:1234`).
- buildkitd.toml: `[registry."registry.dev.biyard.co"]` mirror → `http://registry.infra.svc.cluster.local:5000`, `http = true` — push/pull이 클러스터 내부로 직결, ingress auth 우회(내부 경로라 자격증명 불필요).
- 러너에서 사용 계약(워크플로우 마이그레이션 가이드의 핵심 한 줄):
  ```bash
  buildctl --addr tcp://buildkitd.infra.svc:1234 build \
    --frontend dockerfile.v0 --local context=. --local dockerfile=. \
    --output type=image,name=registry.dev.biyard.co/<repo>/<app>:<tag>,push=true
  ```
- 캐시: registry 캐시(`--export-cache type=registry,ref=...` / `--import-cache`)를 가이드에 포함. buildkitd 자체 로컬 캐시용 PVC 50Gi.

### 3.5 이미지 pull 경로 (노드 registries.yaml)

- 양 노드 `/etc/rancher/k3s/registries.yaml`:
  ```yaml
  mirrors:
    "registry.dev.biyard.co":
      endpoint: ["http://<registry ClusterIP>:5000"]
  ```
  → 파드 `image: registry.dev.biyard.co/...` pull이 내부 HTTP로 처리되어 imagePullSecret 불필요. 적용 시 노드별 k3s 서비스 재시작 필요(순차, 러너 컷오버 전에 수행).
- registry Service에 **고정 `clusterIP: 10.43.200.5`를 명시**한다(k8s/charts/registry 수정; 기존 동적 IP에서 변경 시 Service 재생성 필요 — Service는 stateless라 무해). registries.yaml은 이 고정 IP를 사용한다. (NodePort 방식은 채택하지 않음.)
- 외부(개발자 Mac, lima docker VM) push/pull은 기존 ingress(`https://registry.dev.biyard.co`, basic auth) 그대로.

### 3.6 PR 정적 프리뷰 (`k8s/charts/pr-webroot/`)

- `PVC pr-webroot`(local-path RWO 50Gi) — 러너 파드들과 프리뷰 nginx가 **모두 lima 노드 고정이므로 RWO 공유 가능**(RWO는 노드 단위 제약).
- `Deployment pr-nginx`(nginx:alpine) — PVC를 `/usr/share/nginx/html`에 ro 마운트, 기존 `asset-pr.conf`의 정적 서빙 규칙(경로→디렉토리 매핑, SPA fallback 등)을 ConfigMap으로 이식.
- Ingress: `*.pr.biyard.co` (와일드카드 host) → pr-nginx. TLS는 tls 차트 `certs:`에 `{dnsZone: pr.biyard.co, secretName: pr-biyard-co-tls}` 추가로 와일드카드 발급(기존 certbot의 `*.pr.biyard.co` 수동 인증서 대체 — certbot 잔재 TXT 충돌 주의사항은 miner와 동일).
- Mac nginx: stream SNI 맵에 `.pr.biyard.co → k3s_ingress` 추가(:80은 asset-pr.conf의 기존 리다이렉트 블록 재사용). **주의: SNI는 호스트 패턴 열거가 불가능하므로 이 전환 시점부터 동적 per-PR compose 프리뷰(`<svc>-<pr>.pr.biyard.co` → biyard-dev 컨테이너)도 k3s로 라우팅되어 접근이 끊긴다 — 빅뱅 결정(러너 docker 제거로 신규 compose 프리뷰 생성도 불가)과 정합하며 감수한다.** asset-pr.conf의 vhost 블록들은 롤백 대비로 두고 후속 정리한다.
- 기존 `nginx/webroot` 콘텐츠는 1회 복사(러너 파드 경유 `kubectl cp` 또는 임시 파드).
- DNS: `*.pr.biyard.co`가 현재 어디를 가리키는지 구현 시 확인 — Mac(121.131.101.30)으로 오면 SNI 추가만으로 충분.

### 3.7 빅뱅 컷오버 절차

1. 인프라 선배치: registry 미러(registries.yaml), buildkitd, pr-webroot, 러너 이미지 push까지 완료. 이 시점까지 compose 러너는 정상 가동.
2. 컷오버(짧은 CI 정지 창): compose runner1~9 정지 → 상태 파일 이관 스크립트 실행(§5) → k3s `runner` StatefulSet 기동 → GitHub org Settings > Actions > Runners에서 9개 전부 Idle 확인.
3. compose에서 runner1~9 서비스 블록 제거(§5의 별도 커밋). `runners/` 디렉토리는 롤백 대비 보존.
4. **사후 워크플로우 마이그레이션(스코프 밖, 병행 진행)**: docker 의존 잡은 이 시점부터 실패한다(감수하기로 결정). 각 레포에서 buildctl/k8s 배포로 전환. 전환 가이드(§3.4 계약, kubectl in-cluster, `/root/nginx` 경로 유지)를 `k8s/README-runners.md`로 제공.

### 3.8 롤백

- k3s StatefulSet scale 0 → compose 러너 블록 복원(git revert) → `docker compose up -d runner1 ... runner9`. 상태 디렉토리 원본이 `runners/`에 남아 있으므로 재등록 불필요. 단 k3s 러너가 `_work`를 새로 만들었어도 등록 파일은 불변이라 안전.

## 4. 테스트 / 성공 기준

- 러너: GitHub org 러너 목록에 runner1~9 Idle. 테스트 워크플로우(간단한 echo 잡, `runs-on: [self-hosted, linux, arm64]`)가 k3s 러너에서 성공.
- 빌드: 러너 파드 안에서 §3.4 buildctl 명령으로 샘플 이미지 빌드→registry push 성공, k3s에서 그 이미지로 파드 기동(pull 경로 검증).
- kubectl: 러너 파드에서 `kubectl get ns` 성공(SA 경유), 프리뷰 네임스페이스 생성·삭제 시나리오 성공.
- 프리뷰: `pr-webroot` PVC에 파일을 쓰고 `https://<something>.pr.biyard.co`에서 유효 TLS로 조회. 기존 정적 프리뷰 URL 회귀 확인.
- 회귀: miner/dev 도메인, n8n 등 기존 vhost 정상. compose에 남은 서비스(nginx, certbot 등) 정상.

## 5. 산출물 목록

1. `Dockerfile.runner-k8s` + 러너 이미지 push
2. `k8s/charts/runners/`, `k8s/charts/buildkitd/`, `k8s/charts/pr-webroot/` + helmfile 릴리스 3개
3. tls 차트 `certs:`에 pr.biyard.co 추가
4. 노드 registries.yaml 설정(수동 절차 문서화 + 적용)
5. 상태 이관 스크립트 `migrate-runner-state.sh` (compose 정지 → 등록 파일만 PVC로 복사)
6. Mac nginx SNI/:80 갱신, `asset-pr.conf` 정적 vhost 정리
7. docker-compose.yml에서 runner1~9 제거 (컷오버 후 별도 커밋)
8. `k8s/README-runners.md` — 워크플로우 마이그레이션 가이드(빌드 계약, kubectl, 프리뷰 경로)

## 6. 리스크 / 완화

- **docker 의존 잡 실패(의도된 감수)**: 컷오버 직후부터 워크플로우 전환 완료까지. 가이드 선배포로 전환 기간 최소화.
- **상태 이관 실패**: 등록 파일 손상 시 해당 러너만 수동 재등록(`config.sh remove` 후 재등록)으로 복구 — 전체 롤백 불필요.
- **RWO PVC 공유 전제**: 러너·pr-nginx가 반드시 같은 노드여야 함. nodeSelector가 이를 보장하며, Pi로의 스케줄은 금지(사용자 결정: 빌드 성능).
- **privileged buildkitd**: 단일 공유 데몬이라 러너 간 빌드 격리는 없음(로컬 개발 인프라 수용). rootless 전환은 후속 검토.
- **runner 라벨의 `docker`**: 라벨은 유지되지만 실체가 없음 — 워크플로우 전환 완료 후 라벨 정리는 선택 사항으로 남김.

## 7. 스코프 외

- 각 레포 워크플로우의 buildctl/k8s-preview 전환 (가이드만 제공)
- ARC(actions-runner-controller) 전환
- Docker Desktop 완전 퇴역 (엣지 nginx·certbot이 아직 compose에 남음)
- registry ingress 폐쇄(내부 전용화) — 러너 전환 후 lima 빌드 VM 사용 여부를 보고 결정

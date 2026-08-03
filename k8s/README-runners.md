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

# k3s 인프라 마이그레이션 설계 (minio / postgres / qdrant / redpanda / redpanda-console)

- 날짜: 2026-08-03
- 상태: 사용자 승인됨 (구현 전)
- 스코프: docker-compose의 데이터 인프라 5종(+부속 minio-init, pgweb/adminer)을 기존 k3s 클러스터로 이관. ollama, n8n, runner, openvpn, certbot 등 나머지 compose 서비스는 스코프 외.

## 1. 배경 / 현재 상태

### Docker 측 (Mac 호스트)
- `docker-compose.yml`이 `biyard-dev` external 네트워크에서 minio, minio-init, postgres, pgweb(adminer), qdrant, redpanda, redpanda-console을 운영.
- 데이터는 레포 하위 `./infra/{minio,postgres,qdrant,redpanda}` 바인드 마운트.
- 소비자(asset compose, 러너 등)는 컨테이너 이름으로 직접 접근: `minio:9000`, `postgres:5432`, `redpanda:9092`.
- Mac nginx(:80/:443)가 `s3.|pg.|redpanda.|qdrant.miner.biyard.co` 웹 UI를 TLS 종단 후 프록시 (`nginx/conf.d/infra.conf`). 인증서는 certbot 수동 DNS-01 와일드카드 (`certbot/etc/live/miner.biyard.co`).
- 공인 트래픽 경로: `*.miner.biyard.co` → `hackartist.iptime.org`(121.131.101.30) → 라우터 포트포워딩 :80/:443 → Mac nginx. Mac nginx는 이관 대상 외 vhost도 다수 서빙 (`asset.miner.biyard.co`, `essence.miner.biyard.co`, `*.pr.biyard.co`, `n8n.hackartist.io`, `summer.biyard.co`, `miner.ratel.foundation`).

### k3s 측
- 노드: `lima-k3s-server`(control-plane, 192.168.0.54, Lima VM on Mac, arm64), `hackartist-pi`(worker, 192.168.0.34, RPi5, arm64). k3s v1.36.2.
- `infra` 네임스페이스에 ingress-nginx(helm release `ingress-nginx`, DaemonSet, **hostNetwork=true** → 각 노드 :80/:443 직접 리슨). LoadBalancer svc는 `<pending>`이지만 hostNetwork라 무관.
- StorageClass: `local-path`(기본, 노드 고정형)만 존재.
- Helm v4.2.3 설치됨. helmfile 미설치.

## 2. 사용자 결정 사항

| 결정 | 선택 |
|---|---|
| 기존 데이터 | 이관하지 않음 — 빈 상태로 새로 시작 (버킷/스키마 프로비저닝만) |
| 소비자 접근 | 소비자도 곧 k3s로 이동 예정 → 이관 후 k8s 내부 DNS 사용, 브리지 불필요 |
| 스토리지 노드 | 전 스테이트풀 워크로드 `lima-k3s-server` 고정 |
| 매니페스트 관리 | Helm — 공식 차트(minio/qdrant/redpanda) + 소형 자체 차트(postgres/adminer) 혼합, helmfile 통합 |
| 웹 UI / TLS | k3s ingress로 완전 이관 — cert-manager(Route53 DNS-01) + Mac nginx는 해당 호스트만 SNI 패스스루 |

## 3. 아키텍처

### 3.1 레포 구조

```
k8s/
├── helmfile.yaml          # 전체 릴리스 선언 (infra 네임스페이스)
├── values/
│   ├── minio.yaml
│   ├── qdrant.yaml
│   ├── redpanda.yaml
│   └── cert-manager.yaml
└── charts/
    └── pg-stack/          # 자체 소형 차트: postgres + adminer
```

배포는 `helmfile apply` 단일 명령. helmfile은 brew로 설치.

### 3.2 서비스 구성

공통: `namespace: infra`, 스테이트풀 워크로드는 `nodeSelector: {kubernetes.io/hostname: lima-k3s-server}`, PVC는 `local-path`.

| 서비스 | 차트 | 핵심 values | 내부 주소 |
|---|---|---|---|
| minio | 공식 `minio/minio` (charts.min.io) | standalone, rootUser/rootPassword=minioadmin, `MINIO_BROWSER_REDIRECT_URL=https://s3.miner.biyard.co`, buckets: `assets-local-uploads`, `assets-local-doc-converter-temp` | `minio.infra.svc:9000` (API), `:9001`(console) |
| minio ilm | 자체 post-install Job(또는 차트 훅) — `mc ilm rule add --expire-days 1 .../assets-local-doc-converter-temp` | 기존 minio-init 대체 | — |
| postgres | 자체 `pg-stack` 차트, `postgres:16-alpine` StatefulSet | POSTGRES_USER/PASSWORD/DB=asset, PVC | `postgres.infra.svc:5432` + **NodePort 30432** (호스트 `make test-pg`용) |
| adminer | `pg-stack` 차트 내 Deployment | `ADMINER_DEFAULT_SERVER=postgres` | UI 전용 |
| qdrant | 공식 `qdrant/qdrant-helm` | 단일 replica, persistence | `qdrant.infra.svc:6333` |
| redpanda | 공식 `redpanda/redpanda` | replicas=1, TLS **비활성**, resources ~512M/1cpu, `auto_create_topics_enabled=true`, console 서브차트 enabled | 내부 Kafka listener: `redpanda-0.redpanda.infra.svc.cluster.local:9093` (차트 기본; 구현 시 실제 광고 주소 확인해 소비자 이관 가이드에 기록) |

주의: 소비자들이 쓰던 `redpanda:9092`/`postgres:5432` 등 이름은 k3s 이관 시 svc DNS로 바뀐다. 소비자 이관은 별도 작업이며, 이 스펙 산출물에는 이관 후 접속 주소 표를 README(또는 `k8s/README.md`)로 남긴다.

### 3.3 TLS / 인그레스

- cert-manager를 helm으로 설치(`cert-manager` 네임스페이스), Route53 DNS-01 `ClusterIssuer`(Let's Encrypt) 구성. `*.miner.biyard.co` 와일드카드 `Certificate` 1장을 `infra` 네임스페이스 Secret으로 발급.
- Route53 권한(AWS access key, `route53:ChangeResourceRecordSets` 등)을 가진 자격증명 Secret은 **사용자가 값 제공** — 레포에는 생성 절차만 문서화하고 값은 커밋하지 않는다.
- Ingress 4개 (`ingressClassName: nginx`):
  - `s3.miner.biyard.co` → minio console(:9001)
  - `pg.miner.biyard.co` → adminer(:8080)
  - `redpanda.miner.biyard.co` → redpanda console(:8080)
  - `qdrant.miner.biyard.co` → qdrant(:6333). 기존 `/` → `/dashboard` 리다이렉트는 ingress-nginx annotation(`permanent-redirect` 계열)으로 유지한다.

### 3.4 Mac nginx 엣지 리팩토링 (SNI 패스스루)

라우터의 :443은 Mac 한 곳으로만 포워딩되므로, 이관 4개 호스트만 k3s로 넘기기 위해 Mac nginx를 다음 구조로 변경:

```
stream {
  map $ssl_preread_server_name $backend {
    s3.miner.biyard.co        k3s;
    pg.miner.biyard.co        k3s;
    redpanda.miner.biyard.co  k3s;
    qdrant.miner.biyard.co    k3s;
    default                   local_https;
  }
  upstream k3s        { server 192.168.0.54:443; }
  upstream local_https{ server 127.0.0.1:8443; }
  server { listen 443; proxy_pass $backend; ssl_preread on; }
}
```

- 기존 http{} 의 모든 `listen 443 ssl` vhost는 `listen 8443 ssl`로 일괄 변경 (동작 동일, 스트림 뒤로 이동).
- :80은 http 레벨에서 이관 4개 호스트만 `192.168.0.54:80`으로 proxy_pass(HTTPS 리다이렉트는 k3s ingress가 수행), 나머지 vhost는 기존 유지.
- DNS-01을 쓰므로 ACME용 :80 webroot 경로는 이관 호스트에 불필요.
- 실제 클라이언트 IP: 패스스루라 k3s ingress에는 Mac IP로 보임. 로컬 개발 인프라이므로 허용(필요 시 proxy_protocol은 후속 작업).

### 3.5 전환 및 정리 순서

1. k3s 스택 배포(helmfile) → 스모크 테스트 통과 확인.
2. Mac nginx 리팩토링 적용(reload) → 4개 도메인이 k3s 인증서로 서빙되는지 확인. 나머지 vhost 회귀 확인 (`asset.miner.biyard.co`, `n8n.hackartist.io` 등 응답 확인).
3. docker-compose에서 minio, minio-init, postgres, pgweb, qdrant, redpanda, redpanda-console 제거. `nginx/conf.d/infra.conf`에서 이관된 4개 vhost 블록 제거(ollama/open-webui 블록은 유지).
4. `./infra/{minio,postgres,qdrant,redpanda}` 데이터 디렉토리는 삭제하지 않고 보존(수동 정리 시점은 사용자 판단).

### 3.6 에러 처리 / 리스크

- **lima VM 소멸 리스크**: local-path PV가 lima VM 디스크에 있으므로 VM 재생성 시 데이터 소실. 빈 상태 시작을 선택했고 로컬 개발용이므로 수용. `k8s/README.md`에 명시.
- **redpanda 차트 무게**: 공식 차트가 로컬 대비 무거울 수 있음. 구현 중 values로 축소가 과도하게 어려우면 pg-stack처럼 자체 StatefulSet로 폴백 가능(구현 계획에 체크포인트로 명시).
- **arm64 호환**: 대상 이미지(minio, postgres:16-alpine, adminer, qdrant, redpanda) 모두 arm64 지원 확인됨(현재 compose도 arm Mac에서 동일 이미지 구동 중).
- **nginx 리팩토링 회귀**: stream 도입은 전 vhost에 영향. 적용 전 `nginx -t`, 적용 후 기존 도메인 스모크 체크를 전환 절차에 포함.

## 4. 테스트 / 성공 기준

- `kubectl -n infra get pods` 전부 Ready.
- postgres: 호스트에서 `psql -h 192.168.0.54 -p 30432 -U asset -d asset -c 'select 1'` 성공.
- minio: 클러스터 내 일회성 `minio/mc` Pod에서 `mc ls`로 버킷 2개 존재 + `mc ilm rule ls`로 만료 규칙 확인, `https://s3.miner.biyard.co` 콘솔 접속(유효한 LE 인증서).
- qdrant: `https://qdrant.miner.biyard.co/collections` 200.
- redpanda: console UI에서 브로커 1개 확인, 테스트 토픽 produce/consume(rpk 또는 console).
- 회귀: `asset.miner.biyard.co`, `n8n.hackartist.io`, `*.pr.biyard.co` 정상 응답.

## 5. 스코프 외 (후속 작업)

- 소비자(asset compose, 러너 등)의 k3s 이관 및 접속 주소 변경.
- ollama/open-webui, n8n 등 나머지 compose 서비스 이관.
- proxy_protocol 기반 실제 클라이언트 IP 보존.
- Mac nginx 완전 퇴역.

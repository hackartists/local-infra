# Backups — k3s infra → AWS S3

클러스터 데이터는 전부 `lima-k3s-server` 노드의 `local-path` 디스크 한 장에만
있다. 노드가 죽거나 PVC를 지우면 복구 수단이 없으므로, S3 사본이 유일한
방어선이다.

```
Postgres  pg_dumpall | gzip  ──일 1회──▶ s3://biyard-backup-postgres/postgres/<ts>.sql.gz
                                          (30일 뒤 라이프사이클로 만료)

MinIO     mc mirror (append-only) ──6시간──▶ s3://biyard-<원본 버킷명>/…
                                          (--remove 없음: MinIO에서 지워도 S3엔 남음)
```

차트: `k8s/charts/backup` (helmfile 릴리스 `backup`, ns `infra`).
CronJob 두 개 — `postgres-backup`, `minio-backup`.

## 설계 근거

- **Postgres는 파일 복사가 아니라 논리 덤프.** local-path PVC를 통째로 복사해봐야
  실행 중인 인스턴스의 데이터 디렉터리는 정합성이 깨진 상태다. `pg_dumpall`은
  개별 DB뿐 아니라 롤/글로벌까지 담아서, PR 프리뷰가 만든 DB도 자동으로 따라온다.
- **MinIO는 이미 객체라 mirror가 자연스럽다.** 단 `--remove`를 쓰지 않는다.
  MinIO 쪽 삭제가 S3로 전파되면 백업이 아니라 그냥 복제본이 된다.
- **백업 IAM 사용자에게 Delete 권한을 주지 않는다.** 보존 만료는 S3
  라이프사이클(계정 측)이 처리한다. 클러스터 자격증명이 유출돼도 과거 백업을
  지울 수 없다.
- **S3 버킷명은 전역 유일**해야 해서 MinIO 버킷명 앞에 `biyard-` 접두사를 붙인다
  (`values.yaml`의 `minio.bucketPrefix`). `assets-local-uploads` 같은 이름은 남의
  계정이 선점했을 가능성이 높다.

## AWS 준비 (1회)

버킷은 CronJob이 `mc mb -p`로 알아서 만든다(MinIO 미러 대상). Postgres 버킷과
라이프사이클 규칙만 사람이 만든다.

```bash
aws s3api create-bucket --bucket biyard-backup-postgres --region ap-northeast-2 --create-bucket-configuration LocationConstraint=ap-northeast-2
```

보존 30일 (Postgres 덤프만 — MinIO 미러는 만료시키지 않는다):

```bash
aws s3api put-bucket-lifecycle-configuration --bucket biyard-backup-postgres --lifecycle-configuration '{"Rules":[{"ID":"expire-30d","Status":"Enabled","Filter":{"Prefix":"postgres/"},"Expiration":{"Days":30}}]}'
```

전용 IAM 사용자 정책 (Delete 없음, `biyard-*` 버킷으로 한정):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:CreateBucket", "s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::biyard-*" },
    { "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::biyard-*/*" }
  ]
}
```

## 클러스터 시크릿 (레포에 값 없음)

```bash
kubectl -n infra create secret generic backup-s3-credentials --from-literal=access-key-id='...' --from-literal=secret-access-key='...'
```

## 운영

스케줄 확인:

```bash
kubectl -n infra get cronjob postgres-backup minio-backup
```

즉시 1회 실행 — 배포 직후 반드시 한 번 돌려서 검증할 것:

```bash
kubectl -n infra create job --from=cronjob/postgres-backup pg-backup-manual
```

```bash
kubectl -n infra logs -l job-name=pg-backup-manual --all-containers --follow
```

```bash
kubectl -n infra create job --from=cronjob/minio-backup minio-backup-manual
```

최근 백업 목록:

```bash
aws s3 ls s3://biyard-backup-postgres/postgres/ | tail
```

## 복구

Postgres — `pg_dumpall`은 평문 SQL이라 `psql`로 되돌린다. 롤까지 포함되므로
빈 인스턴스에 그대로 먹이면 된다.

```bash
aws s3 cp s3://biyard-backup-postgres/postgres/<ts>.sql.gz - | gunzip > restore.sql
```

```bash
kubectl -n infra exec -i postgres-0 -- psql -U asset -d postgres < restore.sql
```

MinIO — 방향만 뒤집는다. `mc` 파드를 띄우고 src/dst를 반대로 건다:

```bash
kubectl -n infra run mc --rm -it --image=minio/mc --restart=Never -- sh
```

```
mc alias set src https://s3.ap-northeast-2.amazonaws.com "$KEY" "$SECRET"
mc alias set dst http://minio:9000 minioadmin minioadmin
mc mirror --overwrite src/biyard-assets-local-uploads dst/assets-local-uploads
```

## 주의

- **Mac이 잠들면 CronJob도 멈춘다.** `startingDeadlineSeconds: 3600`이라 깨어난 뒤
  1시간 안이면 놓친 회차를 따라잡지만, 며칠 잠들어 있었다면 그 기간은 그냥 비어
  있다. 백업 존재 여부를 주기적으로 눈으로 확인할 것.
- **`postgres.password`가 `pg-stack/values.yaml`과 중복**이다. pg-stack 쪽이 원본이니
  비밀번호를 바꾸면 양쪽 다 고쳐야 한다.
- MinIO 미러에는 만료 정책이 없어 S3 용량이 단조 증가한다. 커지면 `biyard-*`에
  Glacier 전환 규칙을 거는 편이 낫다.

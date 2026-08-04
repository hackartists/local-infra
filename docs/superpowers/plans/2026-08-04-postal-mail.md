# Postal Mail Server on k3s Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Postal on k3s serving mail domain `mail.biyard.co` — direct outbound from the home IP, inbound MX → Postal webhook → Redpanda topic `postal.inbound`.

**Architecture:** Local Helm charts (`k8s/charts/postal`, `k8s/charts/mail-bridge`) added to `k8s/helmfile.yaml`, ns `infra`. MariaDB + postal web/smtp/worker (smtp via hostPort 25 on lima-k3s-server), Redpanda Connect bridging Postal's HTTP webhook to Kafka. DNS in Route53 biyard.co zone using the cluster's existing credentials.

**Tech Stack:** Postal v3 (arm64 image built from source — official image is amd64-only), MariaDB 11.4, Redpanda Connect, helmfile, cert-manager wildcard `dev-biyard-co-tls`.

## Global Constraints

- Nodes are **arm64** (lima-k3s-server 192.168.0.54, hackartist-pi). Postal pods pinned to `kubernetes.io/hostname: lima-k3s-server` (hostPort + local image import, same as openvpn).
- Repo convention: secrets are NEVER committed — imperative `kubectl create secret`, documented for fresh bootstrap (precedent: `console-basic-auth`).
- Public IP as of writing: `121.131.101.30`. Home IP change ⇒ manual Route53 A-record update.
- Redpanda: TLS disabled, plaintext Kafka at `redpanda-0.redpanda.infra.svc.cluster.local:9093`, `auto_create_topics_enabled: true`.
- Existing wildcard TLS secret `dev-biyard-co-tls` (infra ns) covers `postal.dev.biyard.co` — no new cert work.
- helmfile deploys: `helmfile -f k8s/helmfile.yaml apply` (run `-l name=postal` etc. for a single release).
- Verification is against the live cluster (no unit-test framework here): each task ends with kubectl/curl checks and a commit.

---

### Task 1: Secrets + MariaDB (chart `k8s/charts/postal`, DB layer)

**Files:**
- Create: `k8s/charts/postal/Chart.yaml`
- Create: `k8s/charts/postal/values.yaml`
- Create: `k8s/charts/postal/templates/mariadb.yaml`
- Modify: `k8s/helmfile.yaml` (add `postal` release)

**Interfaces:**
- Produces: Secret `postal-secrets` (keys `db-password`, `mariadb-root-password`, `rails-secret-key`, `admin-password`, `signing.key`); Service `postal-mariadb:3306`; MariaDB user `postal` with rights on `postal%`.* (message-db creates per-server DBs `postal-*`).

- [ ] **Step 1: Create the imperative secret** (skip keys that already exist if re-running)

```bash
kubectl -n infra create secret generic postal-secrets \
  --from-literal=db-password="$(openssl rand -hex 16)" \
  --from-literal=mariadb-root-password="$(openssl rand -hex 16)" \
  --from-literal=rails-secret-key="$(openssl rand -hex 64)" \
  --from-literal=admin-password="$(openssl rand -base64 12 | tr -d '=+/')" \
  --from-file=signing.key=<(openssl genrsa 2048)
```

- [ ] **Step 2: Write Chart.yaml + values.yaml**

`k8s/charts/postal/Chart.yaml`:
```yaml
apiVersion: v2
name: postal
description: Postal mail server (web/smtp/worker) + MariaDB
type: application
version: 0.1.0
```

`k8s/charts/postal/values.yaml`:
```yaml
# Official ghcr.io/postalserver/postal images are amd64-only; this arm64
# image is built from source on the lima docker VM and imported into the
# server node's containerd (no registry), same pattern as openvpn:
#   git clone https://github.com/postalserver/postal /tmp/postal-src
#   git -C /tmp/postal-src checkout <tag>
#   docker --context lima-docker build -t postal:<tag>-arm64 /tmp/postal-src
#   docker --context lima-docker save postal:<tag>-arm64 | \
#     limactl shell k3s-server -- sudo k3s ctr images import -
# Bump the tag on upgrades so the rollout picks it up.
image: postal:3.3.4-arm64
mariadbImage: mariadb:11.4

# hostPort 25 + locally-imported image: pin to the lima node (like openvpn).
nodeSelector:
  kubernetes.io/hostname: lima-k3s-server

webHostname: postal.dev.biyard.co
smtpHostname: mail.biyard.co
mailDomain: mail.biyard.co

# Host port 25 <- router forwards TCP 25 here. In-container smtp listens on
# 2525 so the process doesn't need root/NET_BIND_SERVICE.
smtpHostPort: 25
smtpContainerPort: 2525
webPort: 5000

storageClass: local-path
mariadbStorage: 8Gi

ingress:
  enabled: true
  className: nginx
  tlsSecret: dev-biyard-co-tls

secretName: postal-secrets
```

- [ ] **Step 3: Write templates/mariadb.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postal-mariadb-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {{ .Values.storageClass }}
  resources:
    requests:
      storage: {{ .Values.mariadbStorage }}
---
# message_db creates one database per Postal mail server (postal-server-N),
# so the postal user needs rights on the postal% pattern, not just one DB.
# initdb scripts only run on an empty datadir.
apiVersion: v1
kind: ConfigMap
metadata:
  name: postal-mariadb-init
data:
  grant.sql: |
    GRANT ALL PRIVILEGES ON `postal%`.* TO 'postal'@'%';
    FLUSH PRIVILEGES;
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postal-mariadb
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postal-mariadb
  template:
    metadata:
      labels:
        app: postal-mariadb
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      containers:
        - name: mariadb
          image: {{ .Values.mariadbImage }}
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secretName }}
                  key: mariadb-root-password
            - name: MARIADB_DATABASE
              value: postal
            - name: MARIADB_USER
              value: postal
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secretName }}
                  key: db-password
          ports:
            - containerPort: 3306
              name: mysql
          readinessProbe:
            exec:
              command: ["healthcheck.sh", "--connect", "--innodb_initialized"]
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
            - name: initdb
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postal-mariadb-data
        - name: initdb
          configMap:
            name: postal-mariadb-init
---
apiVersion: v1
kind: Service
metadata:
  name: postal-mariadb
spec:
  selector:
    app: postal-mariadb
  ports:
    - port: 3306
      targetPort: mysql
```

- [ ] **Step 4: Add release to k8s/helmfile.yaml** (after `open-webui`, before `registry`)

```yaml
  - name: postal
    namespace: infra
    chart: ./charts/postal
  - name: mail-bridge
    namespace: infra
    chart: ./charts/mail-bridge
```

(mail-bridge chart arrives in Task 3; add only `postal` now if helmfile errors on the missing dir.)

- [ ] **Step 5: Deploy and verify MariaDB**

```bash
helmfile -f k8s/helmfile.yaml apply -l name=postal
kubectl -n infra rollout status deploy/postal-mariadb --timeout=180s
kubectl -n infra exec deploy/postal-mariadb -- \
  mariadb -upostal -p"$(kubectl -n infra get secret postal-secrets -o jsonpath='{.data.db-password}' | base64 -d)" \
  -e "SHOW GRANTS FOR 'postal'@'%';"
```
Expected: grants include ``ON `postal%`.*``.

- [ ] **Step 6: Commit**

```bash
git add k8s/charts/postal k8s/helmfile.yaml
git commit -m "feat(k8s): postal chart — mariadb layer"
```

---

### Task 2: Build arm64 Postal image and import into k3s

**Files:** none in repo (procedure documented in `values.yaml` comment from Task 1 and in README, Task 7)

**Interfaces:**
- Produces: image `postal:<tag>-arm64` in lima-k3s-server containerd (tag = latest 3.x release, e.g. 3.3.4; adjust values.yaml if different).

- [ ] **Step 1: Clone source and pick latest 3.x tag**

```bash
git clone --depth 50 https://github.com/postalserver/postal /private/tmp/.../scratchpad/postal-src
git -C .../postal-src fetch --tags --depth 1 && git -C .../postal-src tag | sort -V | tail -5
git -C .../postal-src checkout <latest-3.x-tag>
```

- [ ] **Step 2: Build on the arm64 lima docker VM**

```bash
docker --context lima-docker build -t postal:<tag>-arm64 .../postal-src
```
Expected: successful build (ruby base images are multi-arch). If a build stage fails on arm64, capture the error before improvising.

- [ ] **Step 3: Import into k3s containerd**

```bash
docker --context lima-docker save postal:<tag>-arm64 | limactl shell k3s-server -- sudo k3s ctr images import -
limactl shell k3s-server -- sudo k3s ctr images ls | grep postal
```
Expected: `docker.io/library/postal:<tag>-arm64` listed.

- [ ] **Step 4: If tag ≠ 3.3.4, update `image:` in values.yaml and commit**

```bash
git add k8s/charts/postal/values.yaml
git commit -m "chore(k8s): pin postal image tag"
```

---

### Task 3: Postal app resources (config, web/smtp/worker, init job, ingress)

**Files:**
- Create: `k8s/charts/postal/templates/postal.yaml`

**Interfaces:**
- Consumes: `postal-secrets`, `postal-mariadb` (Task 1), image (Task 2).
- Produces: Service `postal-web:5000`; Ingress `postal.dev.biyard.co`; SMTP on `192.168.0.54:25` (hostPort); admin login `hackartists@gmail.com` / secret `admin-password`.

Config strategy: postal.yml lives in a ConfigMap with `@DB_PASSWORD@` / `@RAILS_SECRET@` placeholders; an initContainer renders it into an emptyDir with sed (secrets stay out of git and out of the ConfigMap) and copies `signing.key`. Every postal container mounts the rendered `/config`.

- [ ] **Step 1: Write templates/postal.yaml**

```yaml
# postal.yml template. DB/rails secrets are injected at pod start by the
# render-config initContainer (sed) so they never live in a ConfigMap.
apiVersion: v1
kind: ConfigMap
metadata:
  name: postal-config
data:
  postal.yml: |
    version: 2
    postal:
      web_hostname: {{ .Values.webHostname }}
      web_protocol: https
      smtp_hostname: {{ .Values.smtpHostname }}
      use_ip_pools: false
    web_server:
      default_port: {{ .Values.webPort }}
      default_bind_address: 0.0.0.0
    smtp_server:
      default_port: {{ .Values.smtpContainerPort }}
      default_bind_address: 0.0.0.0
      tls_enabled: false
    dns:
      mx_records:
        - {{ .Values.smtpHostname }}
      smtp_server_hostname: {{ .Values.smtpHostname }}
      spf_include: spf.{{ .Values.mailDomain }}
      return_path_domain: rp.{{ .Values.mailDomain }}
      route_domain: routes.{{ .Values.mailDomain }}
      track_domain: track.{{ .Values.mailDomain }}
    main_db:
      host: postal-mariadb
      username: postal
      password: "@DB_PASSWORD@"
      database: postal
    message_db:
      host: postal-mariadb
      username: postal
      password: "@DB_PASSWORD@"
      prefix: postal
    logging:
      stdout: true
    rails:
      secret_key: "@RAILS_SECRET@"
{{- define "postal.configInit" }}
        - name: render-config
          image: alpine:3.20
          command:
            - sh
            - -c
            - |
              sed -e "s|@DB_PASSWORD@|$DB_PASSWORD|" \
                  -e "s|@RAILS_SECRET@|$RAILS_SECRET|" \
                  /template/postal.yml > /config/postal.yml
              cp /secrets/signing.key /config/signing.key
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secretName }}
                  key: db-password
            - name: RAILS_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secretName }}
                  key: rails-secret-key
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: config-template, mountPath: /template }
            - { name: secrets, mountPath: /secrets }
{{- end }}
{{- define "postal.volumes" }}
      volumes:
        - name: config
          emptyDir: {}
        - name: config-template
          configMap:
            name: postal-config
        - name: secrets
          secret:
            secretName: {{ .Values.secretName }}
{{- end }}
---
# Schema init/migrations. Rerun on every apply; postal initialize is
# idempotent. before-hook-creation keeps old job objects from blocking.
apiVersion: batch/v1
kind: Job
metadata:
  name: postal-initialize
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      initContainers:
{{- include "postal.configInit" . }}
      containers:
        - name: initialize
          image: {{ .Values.image }}
          imagePullPolicy: IfNotPresent
          command: ["postal", "initialize"]
          volumeMounts:
            - { name: config, mountPath: /config }
{{- include "postal.volumes" . }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postal-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postal-web
  template:
    metadata:
      labels:
        app: postal-web
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      initContainers:
{{- include "postal.configInit" . }}
      containers:
        - name: web
          image: {{ .Values.image }}
          imagePullPolicy: IfNotPresent
          command: ["postal", "web-server"]
          ports:
            - containerPort: {{ .Values.webPort }}
              name: http
          readinessProbe:
            httpGet:
              path: /login
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - { name: config, mountPath: /config }
{{- include "postal.volumes" . }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postal-smtp
spec:
  replicas: 1
  # hostPort: only one instance can hold 25 on the node
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postal-smtp
  template:
    metadata:
      labels:
        app: postal-smtp
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      initContainers:
{{- include "postal.configInit" . }}
      containers:
        - name: smtp
          image: {{ .Values.image }}
          imagePullPolicy: IfNotPresent
          command: ["postal", "smtp-server"]
          ports:
            - containerPort: {{ .Values.smtpContainerPort }}
              hostPort: {{ .Values.smtpHostPort }}
              name: smtp
          volumeMounts:
            - { name: config, mountPath: /config }
{{- include "postal.volumes" . }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postal-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postal-worker
  template:
    metadata:
      labels:
        app: postal-worker
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      initContainers:
{{- include "postal.configInit" . }}
      containers:
        - name: worker
          image: {{ .Values.image }}
          imagePullPolicy: IfNotPresent
          command: ["postal", "worker"]
          volumeMounts:
            - { name: config, mountPath: /config }
{{- include "postal.volumes" . }}
---
apiVersion: v1
kind: Service
metadata:
  name: postal-web
spec:
  selector:
    app: postal-web
  ports:
    - port: {{ .Values.webPort }}
      targetPort: http
{{- if .Values.ingress.enabled }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: postal
  annotations:
    # attachment uploads via web UI / API
    nginx.ingress.kubernetes.io/proxy-body-size: 50m
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
    - hosts: [{{ .Values.webHostname | quote }}]
      secretName: {{ .Values.ingress.tlsSecret }}
  rules:
    - host: {{ .Values.webHostname }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: postal-web
                port:
                  number: {{ .Values.webPort }}
{{- end }}
```

Note: `define` blocks are rendered via `include` with proper indent context — verify rendering with `helm template` before applying; adjust indentation until `kubectl apply --dry-run` accepts it.

- [ ] **Step 2: Render check, then deploy**

```bash
helm template k8s/charts/postal | kubectl apply --dry-run=client -f - >/dev/null && echo RENDER-OK
helmfile -f k8s/helmfile.yaml apply -l name=postal
kubectl -n infra wait --for=condition=complete job/postal-initialize --timeout=300s
kubectl -n infra rollout status deploy/postal-web deploy/postal-smtp deploy/postal-worker --timeout=300s
```
Expected: init job Complete (check `kubectl -n infra logs job/postal-initialize` for migration output), all three deploys Ready. If `postal initialize` rejects the config, read its error — config keys may need adjusting for the built version.

- [ ] **Step 3: Create admin user (non-interactive stdin feed)**

```bash
ADMIN_PW=$(kubectl -n infra get secret postal-secrets -o jsonpath='{.data.admin-password}' | base64 -d)
printf 'hackartists@gmail.com\nHack\nArtist\n%s\n' "$ADMIN_PW" | \
  kubectl -n infra exec -i deploy/postal-web -- postal make-user
```
Expected: "User has been created". If stdin feeding fails, fall back to `kubectl exec -it` and report to user.

- [ ] **Step 4: Verify web UI through ingress**

```bash
curl -sk -o /dev/null -w '%{http_code}' https://postal.dev.biyard.co/login --resolve postal.dev.biyard.co:443:192.168.0.54
```
Expected: 200. (DNS for postal.dev.biyard.co already wildcards via Route53; --resolve avoids hairpin dependence.)

- [ ] **Step 5: Verify SMTP listens on the node**

```bash
nc -zvw5 192.168.0.54 25
```
Expected: succeeded.

- [ ] **Step 6: Commit**

```bash
git add k8s/charts/postal
git commit -m "feat(k8s): postal web/smtp/worker + init job + ingress"
```

---

### Task 4: mail-bridge chart (Postal webhook → Redpanda)

**Files:**
- Create: `k8s/charts/mail-bridge/Chart.yaml`
- Create: `k8s/charts/mail-bridge/values.yaml`
- Create: `k8s/charts/mail-bridge/templates/mail-bridge.yaml`
- Modify: `k8s/helmfile.yaml` (if the mail-bridge release wasn't added in Task 1)

**Interfaces:**
- Consumes: Redpanda plaintext Kafka `redpanda-0.redpanda.infra.svc.cluster.local:9093` (auto-create topics on).
- Produces: `http://mail-bridge.infra.svc:4195/inbound` accepting POST; every request body lands in topic `postal.inbound`.

- [ ] **Step 1: Write the chart**

`Chart.yaml`:
```yaml
apiVersion: v2
name: mail-bridge
description: Redpanda Connect bridge — Postal inbound webhook to Kafka topic
type: application
version: 0.1.0
```

`values.yaml`:
```yaml
# Multi-arch official image (arm64 OK).
image: docker.redpanda.com/redpandadata/connect:4
port: 4195
brokers: redpanda-0.redpanda.infra.svc.cluster.local:9093
topic: postal.inbound
```

`templates/mail-bridge.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mail-bridge-config
data:
  connect.yaml: |
    input:
      http_server:
        address: 0.0.0.0:{{ .Values.port }}
        path: /inbound
        allowed_verbs: [ POST ]
    output:
      kafka_franz:
        seed_brokers: [ "{{ .Values.brokers }}" ]
        topic: {{ .Values.topic }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mail-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mail-bridge
  template:
    metadata:
      labels:
        app: mail-bridge
    spec:
      containers:
        - name: connect
          image: {{ .Values.image }}
          args: ["run", "/etc/connect/connect.yaml"]
          ports:
            - containerPort: {{ .Values.port }}
              name: http
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/connect
      volumes:
        - name: config
          configMap:
            name: mail-bridge-config
---
apiVersion: v1
kind: Service
metadata:
  name: mail-bridge
spec:
  selector:
    app: mail-bridge
  ports:
    - port: {{ .Values.port }}
      targetPort: http
```

- [ ] **Step 2: Deploy and verify end-to-end into Kafka**

```bash
helmfile -f k8s/helmfile.yaml apply -l name=mail-bridge
kubectl -n infra rollout status deploy/mail-bridge --timeout=120s
kubectl -n infra run bridge-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://mail-bridge.infra.svc:4195/inbound -H 'Content-Type: application/json' -d '{"probe":"bridge-e2e"}'
kubectl -n infra exec redpanda-0 -- rpk topic consume postal.inbound --num 1 --offset start
```
Expected: consumed record contains `{"probe":"bridge-e2e"}`.

- [ ] **Step 3: Commit**

```bash
git add k8s/charts/mail-bridge k8s/helmfile.yaml
git commit -m "feat(k8s): mail-bridge — postal webhook to redpanda topic postal.inbound"
```

---

### Task 5: DNS records + router port-forward

**Files:** none (records live in Route53; router is manual)

**Interfaces:**
- Consumes: cert-manager ns Secret `route53-credentials` (keys `access-key-id`, `secret-access-key`), region ap-northeast-2.
- Produces: mail.biyard.co resolvable MX/A/SPF/DMARC; TCP 25 reaching 192.168.0.54.

- [ ] **Step 1: Locate the biyard.co hosted zone**

```bash
export AWS_ACCESS_KEY_ID=$(kubectl -n cert-manager get secret route53-credentials -o jsonpath='{.data.access-key-id}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl -n cert-manager get secret route53-credentials -o jsonpath='{.data.secret-access-key}' | base64 -d)
aws route53 list-hosted-zones-by-name --dns-name biyard.co --max-items 1 \
  --query 'HostedZones[0].{Id:Id,Name:Name}' --output table
```
If the IAM policy denies listing, try `list-hosted-zones`; if that also fails, hand the record table (spec) to the user and stop this task.

- [ ] **Step 2: UPSERT the records** (change-batch JSON in scratchpad, then)

Records (TTL 300):
| name | type | value |
|---|---|---|
| mail.biyard.co | A | 121.131.101.30 |
| mail.biyard.co | MX | `10 mail.biyard.co` |
| mail.biyard.co | TXT | `"v=spf1 a mx include:spf.mail.biyard.co ~all"` |
| spf.mail.biyard.co | TXT | `"v=spf1 ip4:121.131.101.30 ~all"` |
| rp.mail.biyard.co | A | 121.131.101.30 |
| rp.mail.biyard.co | MX | `10 mail.biyard.co` |
| rp.mail.biyard.co | TXT | `"v=spf1 a mx include:spf.mail.biyard.co ~all"` |
| _dmarc.mail.biyard.co | TXT | `"v=DMARC1; p=none"` |

```bash
aws route53 change-resource-record-sets --hosted-zone-id <ZONE> --change-batch file://.../mail-dns.json
dig +short MX mail.biyard.co @8.8.8.8   # after propagation
```
Expected: `10 mail.biyard.co.` and A → 121.131.101.30.

- [ ] **Step 3: Ask user to add router forwarding TCP 25 → 192.168.0.54** (blocking user step; same router page as 80/443/1194). After confirmation, verify from outside if possible; otherwise rely on the Task 7 Gmail inbound test.

---

### Task 6: Postal one-time setup (org/server/domain/DKIM/credential/route)

**Files:** none (state lives in Postal's DB; steps recorded in README, Task 7)

**Interfaces:**
- Consumes: admin login from Task 3; mail-bridge URL from Task 4.
- Produces: org `biyard`, mail server `main`, domain `mail.biyard.co` (DKIM-verified), SMTP+API credentials, route `*@mail.biyard.co` → HTTP endpoint `http://mail-bridge.infra.svc:4195/inbound`.

- [ ] **Step 1: Log into https://postal.dev.biyard.co via in-app browser** (admin creds from Task 3). Create organization `biyard`, mail server `main` (mode: Live).
- [ ] **Step 2: Add domain `mail.biyard.co`** under the mail server. Postal shows required DNS incl. the DKIM TXT record name/value.
- [ ] **Step 3: UPSERT the DKIM TXT** (same aws CLI env as Task 5) and any record Postal still flags, then use Postal's "Check my records are correct" until all green.
- [ ] **Step 4: Create credentials**: one SMTP credential and one API credential (Credentials tab). Store for the user:

```bash
kubectl -n infra create secret generic postal-app-credentials \
  --from-literal=smtp-user=... --from-literal=smtp-password=... \
  --from-literal=api-key=...
```
- [ ] **Step 5: Create HTTP endpoint + route**: Webhooks/Endpoints → HTTP Endpoint URL `http://mail-bridge.infra.svc:4195/inbound`, format: delivered raw/JSON per UI options; Routes → `*@mail.biyard.co` → that endpoint.

---

### Task 7: E2E verification + README + memory

**Files:**
- Create: `k8s/README-mail.md`

- [ ] **Step 1: Outbound E2E** — from Postal web UI (or API credential) send a test mail to a user-provided external address (gmail). Expected: arrives (spam folder acceptable); Authentication-Results shows `spf=pass`, `dkim=pass`.
- [ ] **Step 2: Inbound E2E** — user (or Claude via browser gmail if available) sends mail from outside to `test@mail.biyard.co`. Then:

```bash
kubectl -n infra exec redpanda-0 -- rpk topic consume postal.inbound --num 5 --offset start
```
Expected: an event whose payload contains the sent subject/body.

- [ ] **Step 3: Write k8s/README-mail.md** covering: architecture map (router 25 → lima hostPort → postal-smtp; postal route → mail-bridge → postal.inbound), fresh-bootstrap secret creation commands (postal-secrets + regenerated admin), arm64 image build/import procedure, DNS record table + home-IP-change runbook, Postal UI one-time setup, app integration (SMTP endpoint mail.biyard.co:25 in-LAN? no — pods use postal-web API / SMTP 192.168.0.54:25... document exact endpoints: in-cluster SMTP `postal-smtp` has no Service — document adding one if apps need in-cluster SMTP; external apps use mail.biyard.co:25 with SMTP credential), consuming `postal.inbound` with rpk/franz-go, rollback (helmfile destroy -l name=postal,mail-bridge + router rule removal + DNS deletion list).
- [ ] **Step 4: Commit + memory**

```bash
git add k8s/README-mail.md docs/superpowers/plans/2026-08-04-postal-mail.md
git commit -m "docs: postal mail runbook + implementation plan"
```
Update auto-memory: new file `postal-mail-in-k3s.md` + MEMORY.md line (state, credentials location, caveats: PTR/spam risk, home IP change runbook, fresh-bootstrap secrets).

## Self-review notes

- Spec coverage: MariaDB/web/smtp/worker (T1-T3), bridge+topic (T4), DNS+router (T5), Postal setup+DKIM (T6), E2E+docs (T7). arm64 gap discovered during planning → T2.
- Type consistency: secret name `postal-secrets`, DB host `postal-mariadb`, bridge URL `http://mail-bridge.infra.svc:4195/inbound`, topic `postal.inbound` used consistently.
- Known uncertainty flagged inline: postal.yml key names for the built version (T3 Step 2 fallback), helm `define/include` indentation (T3 Step 1 note), `rpk` availability in redpanda-0 container (fallback: `kubectl -n infra exec redpanda-0 -c redpanda -- rpk ...`).

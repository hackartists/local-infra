# k8s/

The Helm charts, `helmfile.yaml`, chart `values/`, and per-service operational
docs that used to live here (`charts/`, `README-backup.md`,
`README-runners.md`, `README-mail.md`, `README-litellm.md`) moved to
[biyard/infra-helm-charts](https://github.com/biyard/infra-helm-charts) on
2026-09-16. That repo now has CI (self-hosted runner, `helmfile apply` on
every push to `main`) — deployment is no longer a manual `helmfile` run from
whoever's laptop has it installed.

What's left here is specific to bootstrapping/operating this physical
cluster, not to any Helm release:

- `rbac/` — one-off `kubectl apply`-style RBAC grants (not helmfile-managed).
- `node-config/registries.yaml` — the k3s node containerd registry mirror
  config (`/etc/rancher/k3s/registries.yaml` on each node).
- `certbot/`, `nginx/` — the Mac-host nginx + certbot setup that predates (and
  in some paths still fronts) the in-cluster ingress.

For anything Helm-chart-shaped — postgres, redpanda, minio, qdrant, ollama,
litellm, openvpn, n8n, postal, cert-manager/tls, the GitHub Actions runners,
etc. — see `biyard/infra-helm-charts` instead.

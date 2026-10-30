# observability-platform

Central logging and monitoring for every project we run: the tribe services (8 services, several
Kubernetes clusters, 3+ replicas each), Replaice Desk (support desk on EC2 with docker-compose), and future
projects. This repo holds infrastructure config only; application code stays in each project's own repo.

Full plan: `docs/plan.md`. Naming, labels and log fields: `docs/conventions.md`. Read both before
changing anything.

## Stack

| Job | Tool |
| --- | --- |
| Collect logs | Fluent Bit (DaemonSet per Kubernetes cluster; Docker log input on EC2 hosts) |
| Store + search logs | Elasticsearch (ECK on Kubernetes, 3 nodes, S3 snapshots) |
| Analyze logs, log alerts | Kibana |
| Dashboards | Grafana (Elasticsearch + Prometheus data sources) |
| Metrics | Prometheus (kube-prometheus-stack, release `prometheus`, namespace `monitoring`, https://prometheus.dev.archietech.co) |
| Deploy | ArgoCD (ApplicationSet rolls Fluent Bit out to every cluster) |

## Layout

- `install/`: the **platform**, the same for every project (Elasticsearch, Kibana, ES setup, Fluent Bit
  base values, Grafana data sources). Installed once, then upgraded deliberately.
- `integrations/<project>/`: **onboarding**, one folder per project (per-cluster identity files, project
  index/role, Kibana searches and alerts, Grafana dashboards, ServiceMonitors). Added whenever a new
  project, cluster or service arrives. `integrations/_template/` is copied to onboard a project.
- `argocd/`: GitOps apps that deploy the above.
- Rule: if it is the same for everyone it goes in `install/`; if it names a project, cluster or service it
  goes in `integrations/`.

## Rules

- Every log line carries `project` and `cluster` labels. `cluster` must be unique across all projects and
  never reused; the Fluent Bit pipeline is shared and only those identity values differ per cluster.
- Indices are `logs-<project>-YYYY.MM.DD`, one shared index template for `logs-*`, retention per project.
- Never commit secrets (passwords, API keys, tokens), not even locally: use placeholders like
  `<ES_PASSWORD>` and real values from a secret manager.
- Pin exact chart and image versions in `install/`.
- Validate YAML/JSON before committing (`helm template`, `kubeconform`, JSON lint).

## Working rules for Claude

- Commit locally only. Never `git push` unless the user explicitly says to push in that message.
- Do not add Co-Authored-By lines for Claude to commits.
- No Go or other toolchains on the host: run tools in Docker containers.
- When the user asks only for an explanation, explain and change nothing.

## Status (2026-10-30)

- Done: plan and conventions agreed (`docs/`). Replaice Desk already exposes Prometheus metrics on port
  9100; its ServiceMonitor, alert rules and Grafana dashboard live in the ReplaiceDesk repo at
  `deploy/monitoring/` (branch `feature/my-work`) and are to be copied to `integrations/replaicedesk/`.
- Not started: everything under `install/`, `integrations/`, `argocd/`.
- No GitHub remote yet. When the new repo exists: `git remote add origin <url>` then push (only when the
  user says so).
- Open decisions: Elasticsearch (ECK) vs AWS OpenSearch; retention period (30 days proposed); final list of
  cluster names.

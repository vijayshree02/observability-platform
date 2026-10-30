# Plan

## Goal

Keep application logs from every project in one durable, searchable place so they survive pod restarts
and redeploys, merge the logs of all replicas and clusters, alert automatically on problems, and show them
in Kibana, Grafana and the Replaice Desk System log page. Metrics already go to Prometheus; logs join them.

Today logs are only visible live in ArgoCD, one pod at a time, and are lost when a pod restarts.

## Architecture

```
 KUBERNETES CLUSTERS (tribe and others)        EC2 HOSTS (Replaice Desk)
 pods ×3+ per service → stdout (JSON)          docker containers → stdout (logfmt)
        │                                              │
 Fluent Bit DaemonSet (one per node)            Fluent Bit (docker log input)
 adds project, cluster, env, k8s labels         adds project, cluster/host, env
 buffers on disk, retries                       buffers on disk, retries
        └──────────────────────┬───────────────────────┘
                               │ HTTPS, write-only credentials, private network
                               ▼
              ELASTICSEARCH (ECK, 3 nodes)
              indices logs-<project>-YYYY.MM.DD, shared template for logs-*
              ILM retention per project, daily snapshots to S3
                 │                 │                     │
                 ▼                 ▼                     ▼
             KIBANA            GRAFANA               REPLAICE DESK
             search, analyze,  dashboards: logs      Admin → System log page
             log alerts        (ES) + metrics (Prom)  (read-only, via ES API)
```

## Install vs integration

| | Install (`install/`) | Integration (`integrations/<project>/`) |
| --- | --- | --- |
| What | The tools themselves | Connecting a project/cluster/app to them |
| Examples | Elasticsearch, Kibana, ES setup, Fluent Bit base values, Grafana data sources | Per-cluster identity file, project index role, Kibana searches/alerts, Grafana dashboards, ServiceMonitors |
| How often | Once, then upgrades | Every new project, cluster or service |
| Owner | DevOps | DevOps + the project team |

## Repo layout (target)

```
observability-platform/
├── CLAUDE.md, README.md, .gitignore
├── docs/                       plan.md, conventions.md, onboarding.md
├── install/
│   ├── elasticsearch/          eck-operator-values.yaml, elasticsearch.yaml, kibana.yaml
│   ├── es-setup/               ilm/, index-templates/, roles/, snapshot-policy.json, apply.sh
│   ├── fluent-bit/             values-base.yaml (shared pipeline)
│   └── grafana/                datasources/
├── integrations/
│   ├── _template/              copy to onboard a project
│   ├── tribe/                  project.yaml, clusters/<cluster>.yaml, es/, kibana/, grafana/, prometheus/
│   └── replaicedesk/           project.yaml, hosts/ec2-desk/, grafana/, prometheus/
├── argocd/                     platform-apps.yaml, fluent-bit-appset.yaml
└── .github/workflows/          validate.yaml (yamllint, helm template, kubeconform, JSON lint)
```

## Reuse across projects and clusters

- The Fluent Bit pipeline is written once in `install/fluent-bit/values-base.yaml`.
- Each cluster adds a ~5-line file with its identity:

  ```yaml
  # integrations/tribe/clusters/tribe-prod-syd.yaml
  project: tribe
  cluster: tribe-prod-syd
  env: prod
  ```

- Helm layers them: `-f install/fluent-bit/values-base.yaml -f integrations/<project>/clusters/<cluster>.yaml`.
- An ArgoCD ApplicationSet deploys Fluent Bit to every registered cluster and picks that cluster's file.
  Onboarding a cluster = register it in ArgoCD + add one file.

## Phases

### 0. Decide
- Elasticsearch (ECK) or AWS OpenSearch (tribe-owners already uses OpenSearch for search).
- Retention per project (default 30 days).
- Final cluster names (`docs/conventions.md`).
- Network path from every cluster and EC2 host to Elasticsearch on 9200 (VPC peering / private LB).

### 1. Install Elasticsearch + Kibana
ECK operator via Helm (`elastic/eck-operator`), then an `Elasticsearch` resource (3 nodes, persistent
volumes) and a `Kibana` resource in namespace `logging`. Expose ES on a private load balancer; Kibana
behind SSO. Check: `_cluster/health` is green.

### 2. Prepare Elasticsearch
ILM policies (`logs-14d`, `logs-30d`, `logs-90d`), the `logs-*` index template (field mapping from
`docs/conventions.md`), roles and users (per-project writer, readers for Grafana and Replaice Desk), S3
snapshot repository and policy. Check: template and policies exist.

### 3. Fluent Bit in Kubernetes clusters
Shared pipeline: `tail /var/log/containers/*.log` (cri/docker multiline) → `kubernetes` filter
(`Merge_Log On`, `Labels On`) → `modify` adds project/cluster/env → filesystem buffer
(`storage.type filesystem`, `Retry_Limit False`) → `es` output (TLS, `Logstash_Format On`,
`Logstash_Prefix logs-<project>`, `Time_Key @timestamp`, `Suppress_Type_Name On`, `Replace_Dots On`).
Credentials from a Kubernetes secret. Pilot one cluster, verify in Kibana (terms aggregation on `cluster`
and `kubernetes.labels.app`), then roll out via the ApplicationSet.

### 4. Fluent Bit on EC2 hosts (Replaice Desk)
Extra compose service reading `/var/lib/docker/containers/*/*.log` with the docker parser, logfmt parser
for Replaice Desk lines, same output, `project: replaicedesk`.

### 5. Kibana
Data views per project (`logs-<project>-*`) and one for all (`logs-*`), saved searches, alert rules (e.g.
more than 20 `level:error` per app in 5 minutes → Slack/email), read-only access for teams.

### 6. Grafana
Elasticsearch data source (read-only user, index `logs-*`, time field `@timestamp`), log dashboard with
`project`/`cluster`/`app`/`pod`/`level` variables: errors per minute, top error messages, recent errors,
next to the Prometheus panels.

### 7. Replaice Desk System log page
Developer work in the ReplaiceDesk repo, when asked: backend reads Elasticsearch (read-only user) with
filters for project/cluster/service/pod/level/time, full-text search, `request_id` tracing, live mode by
polling with `search_after`, links to Kibana/Grafana. Needs the ES URL reachable from the EC2 host and the
read-only credentials.

### 8. Replaice Desk metrics (separate, already built)
App serves `/metrics` on port 9100 (private IP only). To finish: redeploy Replaice Desk, allow TCP 9100
from `172.31.0.0/16` in its security group, apply `servicemonitor.yaml` (fill in the private IP) and
`prometheus-rules.yaml`, import the Grafana dashboard. Files to copy from ReplaiceDesk `deploy/monitoring/`
into `integrations/replaicedesk/`.

## Next steps in this repo

1. Fill `docs/conventions.md` decisions (cluster list, retention, ES vs OpenSearch).
2. Write `install/` (Elasticsearch, Kibana, es-setup, Fluent Bit base, Grafana data sources).
3. Write `integrations/tribe/` with one pilot cluster file, then `argocd/fluent-bit-appset.yaml`.
4. Copy Replaice Desk monitoring files into `integrations/replaicedesk/` and add its EC2 Fluent Bit config.
5. Add `integrations/_template/`, `docs/onboarding.md` and CI validation.
6. Create the GitHub repo, add the remote, push (only when the user says so).

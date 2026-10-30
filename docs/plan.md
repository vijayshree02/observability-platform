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
              data stream logs-<project>, shared template for logs-*
              retention per project (default 10d), daily snapshots to S3
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
├── docs/                       plan.md, conventions.md, system-log-page.md
├── install/
│   ├── logging/                eck-operator-values.yaml, namespace.yaml, storageclass.yaml
│   │   ├── elasticsearch/      elasticsearch.yaml
│   │   ├── kibana/             kibana.yaml, ingress.yaml
│   │   ├── es-setup/           apply.sh, ingest-pipelines/, index-templates/, roles/, snapshots/
│   │   ├── kibana-setup/       apply.sh, data-views/, searches/, roles/, rules/
│   │   ├── grafana-setup/      apply.sh, datasource.json, dashboards/, alerting/
│   │   └── fluent-bit/         values-base.yaml (Kubernetes), docker-host/ (EC2 / Docker hosts)
├── integrations/
│   ├── _template/              copy to onboard a project
│   ├── tribe/                  project.yaml, clusters/<cluster>.yaml, grafana/ (optional dashboards)
│   └── replaicedesk/           project.yaml, hosts/ec2-desk/, grafana/, prometheus/
├── argocd/                     fluent-bit-appset.yaml
└── .github/workflows/          validate.yaml (yamllint, helm template, kubeconform, JSON lint)
```

## Reuse across projects and clusters

- The Fluent Bit pipeline is written once in `install/logging/fluent-bit/values-base.yaml`.
- Each cluster adds a ~5-line file with its identity:

  ```yaml
  # integrations/tribe/clusters/tribe-prod-syd.yaml
  identity:
    project: tribe
    cluster: tribe-prod-syd
    env: prod
  ```

- Helm layers them: `-f install/logging/fluent-bit/values-base.yaml -f integrations/<project>/clusters/<cluster>.yaml`.
- An ArgoCD ApplicationSet deploys Fluent Bit to every registered cluster and picks that cluster's file.
  Onboarding a cluster = register it in ArgoCD + add one file.

## Phases

### 0. Decide
- Elasticsearch (ECK) or AWS OpenSearch (tribe-owners already uses OpenSearch for search).
- Retention per project (default 10 days).
- Final cluster names (`docs/conventions.md`).
- Network path from every cluster and EC2 host to Elasticsearch on 9200 (VPC peering / private LB).

### 1. Install Elasticsearch + Kibana
ECK operator via Helm (`elastic/eck-operator`), then an `Elasticsearch` resource (3 nodes, persistent
volumes) and a `Kibana` resource in namespace `logging`. Expose ES on a private load balancer; Kibana
behind SSO. Check: `_cluster/health` is green.

### 2. Prepare Elasticsearch
`install/logging/es-setup/apply.sh <project>...`: the `logs-platform` index template (field mapping from
`docs/conventions.md`, default retention), one data stream `logs-<project>` per project with its retention,
roles and users (per-project writer, readers for Grafana and Replaice Desk), S3 snapshot repository and
daily policy. Check: template, data streams and roles exist; a manual snapshot succeeds.

### 3. Fluent Bit in Kubernetes clusters
Shared pipeline: `tail /var/log/containers/*.log` (cri/docker multiline) → `kubernetes` filter
(`Merge_Log On`, `Labels On`) → `modify` adds project/cluster/env → filesystem buffer
(`storage.type filesystem`, `Retry_Limit False`) → `es` output (TLS, `Index logs-<project>`,
`Write_Operation create`, `Time_Key @timestamp`, `Suppress_Type_Name On`, `Replace_Dots On`).
Credentials from a Kubernetes secret. Pilot one cluster, verify in Kibana (terms aggregation on `cluster`
and `kubernetes.labels.app`), then roll out via the ApplicationSet.

### 4. Fluent Bit on EC2 hosts (Replaice Desk)
Shared Docker-host pipeline in `install/logging/fluent-bit/docker-host/` (any project on a plain Docker
host). Per host, `integrations/<project>/hosts/<host>/docker-compose.override.yml` sets the identity
(`LOG_PROJECT`, `LOG_CLUSTER`, `LOG_ENV`, `LOG_HOST`), which containers log logfmt, and `tag={{.Name}}` on
every container so each line carries its container name. For Replaice Desk the override sits next to
`docker-compose.yml` in `/opt/replaicedesk`, so no change in the ReplaiceDesk repo is needed.

### 5. Kibana
`install/logging/kibana-setup/apply.sh <project>...`: data views per project (`logs-<project>`, named from
`project.yaml`) and one for all (`logs-*`), saved searches (errors per project, request trace), read-only
team roles `logs_viewer_<project>`, and an error-spike rule per project (more than 20 error lines from one
service in 5 minutes). Kibana's Slack/email connectors need an Elastic Gold licence, so on Basic the
rules show alerts in Kibana and Slack notifications come from Grafana.

### 6. Grafana
`install/logging/grafana-setup/apply.sh <project>...`: Elasticsearch data source (read-only user `grafana`,
`logs-*`), "Logs overview" dashboard (project / cluster / service / level / search filters), the
"Log error spike" alert rule with a Slack contact point, and every `integrations/<project>/grafana/*.json`
dashboard.

### 7. Replaice Desk metrics
Files in `integrations/replaicedesk/prometheus/` (ServiceMonitor + Endpoints for the server's private IP,
7 alert rules) and `integrations/replaicedesk/grafana/` (metrics dashboard, uploaded by grafana-setup).
To finish: redeploy Replaice Desk, allow TCP 9100 from the cluster VPC, fill in the private IP, apply.

### 8. Replaice Desk System log page
Hand-off for the ReplaiceDesk developers: `docs/system-log-page.md` (connection, read-only user
`replaicedesk-syslog`, project registry `observability-projects` for display names, tested queries for
filters, paging, live mode, summary and request tracing). The page itself is built in the ReplaiceDesk repo.

## Status

Phases 1-8 are written and tested on a local cluster (see each folder's README). Still open: the real tribe
cluster names (`integrations/tribe/clusters/`), the Git repo URL for ArgoCD, and the environment values
(Elasticsearch DNS name, Kibana host, cert-manager issuer, Slack webhook, S3 bucket, Replaice Desk private IP).

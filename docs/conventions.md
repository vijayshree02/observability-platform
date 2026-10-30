# Conventions

Agree these before writing config. Everything else (dashboards, alerts, the Replaice Desk System log page)
depends on them.

## Labels on every log line

Set by Fluent Bit. Together they identify where a line came from, even when apps, services or pods share
names across clusters.

| Field | Set by | Example | Rule |
| --- | --- | --- | --- |
| `project` | per-cluster file in `integrations/` | `tribe`, `replaicedesk` | lowercase, no spaces |
| `cluster` | per-cluster file in `integrations/` | `tribe-prod-syd` | **unique across all projects, never reused** |
| `env` | per-cluster file | `dev`, `staging`, `prod` | one of these three |
| `kubernetes.namespace_name` | Fluent Bit kubernetes filter | `tribe` | automatic |
| `kubernetes.labels.app` | Fluent Bit kubernetes filter | `tribe-owners` | automatic, from the pod's `app` label |
| `kubernetes.pod_name` | Fluent Bit kubernetes filter | `tribe-owners-7f9c-a1` | automatic |
| `host` | EC2 hosts only | `ec2-desk` | for non-Kubernetes sources |

## Cluster naming

`<project>-<env>-<region>`, for example `tribe-dev`, `tribe-prod-syd`, `replaicedesk-prod-ec2`.
CI fails a cluster file that has no `project`, `cluster` or `env`, or reuses an existing `cluster`.

## Log fields written by applications

Applications log one JSON object per line to stdout using these names, so every project works in the same
dashboards, alerts and searches.

| Field | Type | Required | Example |
| --- | --- | --- | --- |
| `@timestamp` or `timestamp` | ISO-8601 | yes | `2026-10-30T10:15:32.481Z` |
| `level` | `debug`, `info`, `warn`, `error`, `fatal` | yes | `error` |
| `message` | text | yes | `payment failed` |
| `service` | keyword | recommended | `tribe-owners` |
| `request_id` | keyword | recommended | `abc-123` |
| `error` | text | when there is one | `card declined` |
| `caller` | keyword | optional | `app/payments/service.py:88` |

tribe services already log JSON (`logFormat: json`). Replaice Desk logs logfmt (`key=value`); its Fluent
Bit config parses that with the logfmt parser.

Never make high-cardinality values (`request_id`, `user_id`, `order_id`) into labels or index names; they
stay as fields and are searched.

## Indices and retention

- One data stream per project: `logs-<project>`, e.g. `logs-tribe` (Fluent Bit `Index logs-<project>`,
  `Write_Operation create`). Elasticsearch rolls it over and deletes old data by itself.
- Project names are lowercase letters and digits only (no `-`), so `logs-<project>` never matches
  Elasticsearch's built-in `logs-*-*` templates.
- One index template, `logs-platform` (pattern `logs-*`, priority 500), holds the shared field mapping.
- Each project is configured in `integrations/<project>/project.yaml` (`project`, `display_name`,
  `retention`); the setup scripts read it.
- Retention is set per data stream (`data_retention`). Default 10 days; any project can have its own, and it
  can be changed at any time with `install/logging/es-setup/apply.sh <project>:<days>d`.
- Daily snapshots to S3.

## Access

| Principal | Rights |
| --- | --- |
| Fluent Bit (per project) | append to `logs-<project>` only (`logs_writer_<project>`) |
| Grafana | read `logs-*` (`logs_reader`) |
| Replaice Desk System log page | read `logs-*` and `observability-projects` (`logs_reader`) |
| Project teams in Kibana | read their own `logs-<project>` (`logs_viewer_<project>`) |

## Secrets

Never in git. ES passwords and API keys come from AWS Secrets Manager (External Secrets) or Sealed
Secrets. Files use placeholders such as `<ES_PASSWORD>`.

## Versions

Pin exact Helm chart and image versions in `install/`. Upgrade in one PR per tool, dev clusters first.

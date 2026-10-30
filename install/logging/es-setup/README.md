# Elasticsearch setup (Phase 2)

Run once after Elasticsearch is green, and again whenever a project is added or a setting changes. Every
step creates or updates, so re-running is safe.

## What it creates

| Item | Name | Purpose |
| --- | --- | --- |
| Ingest pipeline | `logs-platform` (`ingest-pipelines/logs-platform.json`) | Runs on every line: lowercases `level` and maps spellings (`warning`→`warn`, ...), copies `msg` to `message`, fills `service` from the Kubernetes `app` label or container name |
| Index template | `logs-platform` (`index-templates/logs-platform.json`) | Field types for every project, default retention. Priority 500 overrides Elasticsearch's built-in `logs` templates. |
| Data stream per project | `logs-<project>`, e.g. `logs-tribe` | Where Fluent Bit appends that project's logs. Rolls over and deletes old data by itself. |
| Retention per project | lifecycle of `logs-<project>` | Data older than the retention is deleted automatically |
| Failure store | on every `logs-<project>` | Lines Elasticsearch cannot index (e.g. a field that is text in one log and an object in another) are kept aside instead of rejected, so Fluent Bit never gets stuck retrying them. View with `GET logs-tribe::failures/_search`. |
| Role `logs_writer_<project>` | `roles/logs_writer.json` | Append to `logs-<project>` only. Cannot read, delete or touch other projects. |
| Role `logs_reader` | `roles/logs_reader.json` | Read all `logs-*` and `observability-projects`. Cannot write. |
| Project registry | index `observability-projects` | One document per project (`project`, `display_name`, `data_stream`, `retention`) for the Replaice Desk System log page |
| Users (optional) | `fluentbit-<project>`, `grafana`, `replaicedesk-syslog` | Created only when their password variable is set |
| Snapshots (optional) | repository `logs-s3`, policy `logs-daily` | Daily backup to S3 at 01:30 UTC, kept 14 days. Only when `SNAPSHOT_BUCKET` is set. |

## Run

```sh
export ES_URL=https://<ES_PRIVATE_DNS>:9200
export ES_PASSWORD=$(kubectl -n logging get secret logs-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
export ES_CACERT=/tmp/es-ca.crt
kubectl -n logging get secret logs-es-http-certs-public -o go-template='{{index .data "ca.crt" | base64decode}}' > "$ES_CACERT"

# Passwords from the secret manager (example: AWS Secrets Manager)
export FLUENTBIT_PASSWORD_TRIBE=$(aws secretsmanager get-secret-value --secret-id logging/fluentbit-tribe --query SecretString --output text)
export FLUENTBIT_PASSWORD_REPLAICEDESK=...
export GRAFANA_PASSWORD=...
export REPLAICEDESK_SYSLOG_PASSWORD=...
export SNAPSHOT_BUCKET=<bucket>          # leave unset to skip snapshots

install/logging/es-setup/apply.sh tribe replaicedesk
```

Projects are given as arguments. Retention and display name come from `integrations/<project>/project.yaml`;
`tribe:30d` overrides the retention for one run, and projects without a `project.yaml` use `RETENTION` (10d).

## Changing settings later

| Change | How |
| --- | --- |
| Retention of one project | `retention:` in `integrations/tribe/project.yaml`, then `apply.sh tribe ...` |
| Default retention for new projects | `RETENTION=14d apply.sh ...` |
| Add a project | `apply.sh tribe replaicedesk newproject` with `FLUENTBIT_PASSWORD_NEWPROJECT` set |
| Rotate a password | Set the new value in the secret manager, export it, run `apply.sh` again |
| Add a field type | Edit `logs-platform.json`, run `apply.sh`. Applies from the next rollover (or `POST logs-tribe/_rollover` now). |

## Snapshots need AWS access

The S3 repository is verified when it is registered, so Elasticsearch must be able to reach the bucket:

1. An S3 bucket, e.g. `<company>-es-snapshots`, in the same region.
2. An IAM role with `s3:ListBucket`, `s3:GetBucketLocation` on the bucket and `s3:GetObject`,
   `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` on its objects.
3. That role given to the Elasticsearch pods (IRSA or EKS Pod Identity), which adds a service account to
   `elasticsearch/elasticsearch.yaml`.

Step 3 is set up together with the real cluster; it cannot be tested on minikube.

## Check

```sh
c() { curl -s --cacert "$ES_CACERT" -u "elastic:$ES_PASSWORD" "$ES_URL$1"; echo; }
c "/_index_template/logs-platform?filter_path=index_templates.name"
c "/_data_stream/logs-*?filter_path=data_streams.name,data_streams.lifecycle"
c "/_security/role/logs_reader,logs_writer_tribe?filter_path=*.indices"
c "/_slm/policy/logs-daily?filter_path=*.policy.schedule"         # only with snapshots
curl -s --cacert "$ES_CACERT" -u "elastic:$ES_PASSWORD" -X POST "$ES_URL/_slm/policy/logs-daily/_execute"   # manual snapshot
```

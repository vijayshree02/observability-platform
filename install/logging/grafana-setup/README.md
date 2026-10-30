# Grafana setup (Phase 6)

Works with any Grafana 11+ (tested with 13.1.1, the version on grafana.dev.archietech.co). Safe to run again.

```sh
export GRAFANA_URL=https://grafana.dev.archietech.co
export GRAFANA_TOKEN=<service account token with Admin role>      # Administration → Service accounts
export ES_URL=https://<ES_PRIVATE_DNS>:9200                         # as reached from Grafana
export ES_CACERT=/tmp/es-ca.crt                                     # Elasticsearch CA (see es-setup)
export GRAFANA_PASSWORD=<Elasticsearch password of user grafana>    # from the secret manager
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...       # from the secret manager
install/logging/grafana-setup/apply.sh tribe replaicedesk
```

## What it creates

| Item | Details |
| --- | --- |
| Data source "Logs (Elasticsearch)" (`logs-elasticsearch`) | Index `logs-*`, read-only user `grafana`, CA-verified TLS |
| Folder "Logs" | Holds everything below |
| Dashboard "Logs overview" | Filters: project, cluster, service, level, free search (e.g. `request_id:abc-123`). Panels: log lines / errors / warnings, services with errors, lines by level, errors per service, top error messages, errors by project and cluster, error lines, all lines |
| Alert rule "Log error spike" | More than `ERROR_THRESHOLD` (20) error lines from one service in 5 minutes, one alert per project + service, checked every minute |
| Contact point `logs-slack` | When `SLACK_WEBHOOK_URL` is set; the rule then always notifies it |
| Project dashboards | Every `integrations/<project>/grafana/*.json` of the projects given, e.g. the Replaice Desk metrics dashboard |

## Changing settings later

| Change | How |
| --- | --- |
| Alert threshold | `ERROR_THRESHOLD=50 apply.sh ...` |
| Slack channel | New webhook in `SLACK_WEBHOOK_URL`, run again |
| A project's own dashboard | Add a JSON file to `integrations/<project>/grafana/`, run again |
| Dashboard layout | Edit in Grafana, export JSON over `dashboards/logs-overview.json`, run again |

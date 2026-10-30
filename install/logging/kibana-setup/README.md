# Kibana setup (Phase 5)

Run after `es-setup/apply.sh`, with the same project list. Safe to run again: every step creates or updates.

```sh
export KB_URL=https://<KIBANA_HOST>
export ES_PASSWORD=$(kubectl -n logging get secret logs-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
install/logging/kibana-setup/apply.sh tribe replaicedesk
```

## What it creates

| Item | Per project `<p>` | Shared |
| --- | --- | --- |
| Data view | `logs-<p>`, named after `display_name` in `integrations/<p>/project.yaml` | `logs-all` = `logs-*`, "All projects" |
| Saved search (Discover → Open) | "`<name>`: errors": error and fatal lines, newest first | "All projects: request trace": replace the id in the search bar to follow one request across pods, services and projects |
| Role | `logs_viewer_<p>`: read-only Kibana, sees only `logs-<p>` | `logs_viewer_all`: read-only, every project |
| Alert rule (Stack Management → Rules) | "`<name>`: error spike": more than `ERROR_THRESHOLD` (20) error lines from one `service` in 5 minutes, checked every minute | |

Give a team access by assigning its role to their users (Stack Management → Users, or the role mapping of
your SSO).

## Notifications

On the free Basic Elastic licence Kibana can not send to Slack, email, Teams or webhooks (those connectors
need Gold). The Kibana rules still run and show active alerts in Kibana; **Slack notifications come from
Grafana** (`grafana-setup`), which has the same rule. With a Gold licence, set `SLACK_WEBHOOK_URL` and this
script attaches Slack to the Kibana rules too.

## Changing settings later

| Change | How |
| --- | --- |
| Alert threshold | `ERROR_THRESHOLD=50 apply.sh ...` |
| Display name | `display_name` in `integrations/<p>/project.yaml`, then `apply.sh ...` |
| Add a project | Add it to the command |

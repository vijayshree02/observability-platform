# Monitoring Replaice Desk with Prometheus and Grafana

Replaice Desk is monitored the same way as the tribe services: it exposes Prometheus metrics, and the
kube-prometheus-stack Prometheus (https://prometheus.dev.archietech.co, release `prometheus`, namespace
`monitoring`) scrapes it through a ServiceMonitor over the private network. The dashboard
`integrations/replaicedesk/grafana/replaice-desk-metrics.json` charts it in https://grafana.dev.archietech.co.

```
Prometheus (cluster) ──private IP:9100──▶ Replaice Desk server ──▶ /metrics
Internet ──443──▶ Caddy ──▶ app                    (/metrics is not on the public site)
```

The difference from tribe-owners: Replaice Desk runs on its own server (docker-compose), not in a pod.
So `servicemonitor.yaml` adds a Service without a selector plus an Endpoints object holding the server's
private IP. To Prometheus it is an ordinary service with job `replaice-desk`. No token is needed because
port 9100 is only reachable from the private network.

## 1. On the Replaice Desk server

`deploy.sh` (through `server-init.sh`) sets this up on the next deploy:

- `config.toml` gets `[app.metrics] enabled = true, address = "0.0.0.0:9100"`.
- `.env` gets `METRICS_BIND_IP=<private IP>`, and docker-compose publishes port 9100 on that IP only.

Check that the IP is the private one (`172.31.x.x` on our AWS VPC) and that metrics answer:

```sh
grep METRICS_BIND_IP /opt/replaicedesk/.env
curl -s http://<private-ip>:9100/metrics | head
```

If the IP is wrong, fix it in `.env` and run `docker compose up -d app`.

## 2. AWS security group

Allow inbound **TCP 9100** on the Replaice Desk server from the cluster's VPC range (`172.31.0.0/16`) only.
Do not open it to `0.0.0.0/0`.

## 3. In the cluster

Replace `DESK_PRIVATE_IP` in `servicemonitor.yaml` with the server's private IP, then:

```sh
kubectl -n monitoring apply -f integrations/replaicedesk/prometheus/servicemonitor.yaml
kubectl -n monitoring apply -f integrations/replaicedesk/prometheus/prometheus-rules.yaml
```

After about a minute `replaice-desk` shows as UP under Status → Target health in Prometheus, and
`up{job="replaice-desk"}` returns 1 in the Query tab.

## 4. Grafana

`install/logging/grafana-setup/apply.sh ... replaicedesk` uploads
`integrations/replaicedesk/grafana/replaice-desk-metrics.json` into the Logs folder. To do it by hand instead:
Dashboards → New → Import → upload that file → pick the Prometheus data source.

## 5. Public uptime check

The ServiceMonitor proves the app is running; it cannot tell whether customers can reach it (DNS, HTTPS
certificate, Caddy). Add an external check of `https://<desk-domain>/health`: a blackbox exporter
`Probe` if one is installed in the cluster, or an uptime service such as UptimeRobot. Alert when it fails
or the certificate is close to expiry.

## What is measured

| Metric | What it tells you |
| --- | --- |
| `replaice_http_requests_total{method,group,status}` | Requests by route group (`api`, `web`, `widget`, `webhook`) and status class (`2xx`…`5xx`) |
| `replaice_http_request_duration_seconds` | Latency histogram per route group |
| `replaice_log_messages_total{level,source}` | Warning and error log lines by the part of the server that logged them |
| `replaice_conversations{status}`, `replaice_conversations_unassigned{status}` | Conversations that are not resolved, and how many have no agent |
| `replaice_agents_connected` | Agents with the app open |
| `replaice_classification_queue_*` | AI classification backlog: waiting (`lag`), in progress (`pending`), failed (`dead`) |
| `replaice_db_connections_*`, `replaice_db_wait_*` | Database pool use and time spent waiting for a connection |
| `go_*`, `process_*` | Memory, CPU, goroutines |

## Alerts (`prometheus-rules.yaml`)

| Alert | Fires when |
| --- | --- |
| ReplaiceDeskDown | The app cannot be scraped for 3 minutes |
| ReplaiceDeskHighErrorRate | More than 5% of requests fail with 5xx for 10 minutes |
| ReplaiceDeskSlowAPI | API p95 latency stays above 2s for 10 minutes |
| ReplaiceDeskErrorSpike | One part of the server logs more than 50 errors in 10 minutes |
| ReplaiceDeskClassificationBacklog | Over 100 conversations wait for AI classification for 15 minutes |
| ReplaiceDeskClassificationDeadLetters | AI classification jobs fail permanently |
| ReplaiceDeskDBPoolExhausted | Over 90% of database connections are in use for 5 minutes |

For the log lines behind an error alert, open **Admin → Teams → System log** in Replaice Desk.

## If the server is not on the private network

If Prometheus cannot reach the server privately, serve metrics on the public site instead: set
`address = ""` and a `token` in `[app.metrics]`, and scrape `https://<desk-domain>/metrics` with that
bearer token (a `ScrapeConfig`, or `additionalScrapeConfigs` in the Helm values).

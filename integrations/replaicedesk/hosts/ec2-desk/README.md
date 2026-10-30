# Replaice Desk server logs (Phase 4)

Collects the logs of every container on the Replaice Desk server (`/opt/replaicedesk`: app, db, redis,
caddy) into Elasticsearch data stream `logs-replaicedesk`.

| File | Where it goes on the server |
| --- | --- |
| `docker-compose.override.yml` (this folder) | `/opt/replaicedesk/docker-compose.override.yml` |
| `install/logging/fluent-bit/docker-host/*` (shared pipeline) | `/opt/replaicedesk/fluent-bit/` |
| Elasticsearch CA certificate | `/opt/replaicedesk/fluent-bit/ca.crt` |

`docker compose` merges the override file automatically, and `deploy/deploy.sh` (ReplaiceDesk repo) leaves
it in place, so nothing changes in the ReplaiceDesk repo and redeploys keep log collection running.

## What ends up in Elasticsearch

| Container | How its lines are read | Fields |
| --- | --- | --- |
| `libredesk_app` | logfmt (`key=value`), colour codes removed | `level`, `message`, `caller`, `sc` and any other key; time = the app's `timestamp` |
| `libredesk_caddy` | JSON | Caddy's fields (`level`, `msg`, ...) |
| `libredesk_db`, `libredesk_redis` | plain text | whole line in `log` |

Every line also gets `project=replaicedesk`, `cluster=replaicedesk-prod-ec2`, `env=prod`, `host=ec2-desk`,
`container` and `service` (the container name).

## Before installing

1. Elasticsearch is set up and `apply.sh ... replaicedesk` has created user `fluentbit-replaicedesk`.
2. Network: the server can reach Elasticsearch's private load balancer on TCP 9200.
   - Server security group: allow outbound 9200 to the Elasticsearch VPC CIDR.
   - `loadBalancerSourceRanges` in `install/logging/elasticsearch/elasticsearch.yaml` includes the server's
     VPC CIDR (172.31.0.0/16 is already there). A server in another VPC or account needs VPC peering first.
3. Replace `<ES_PRIVATE_DNS>` in `docker-compose.override.yml`.

## Install on the server

From this repo on your machine (`SERVER=root@<server-ip>`):

```sh
scp integrations/replaicedesk/hosts/ec2-desk/docker-compose.override.yml $SERVER:/opt/replaicedesk/
ssh $SERVER mkdir -p /opt/replaicedesk/fluent-bit
scp install/logging/fluent-bit/docker-host/* $SERVER:/opt/replaicedesk/fluent-bit/
kubectl -n logging get secret logs-es-http-certs-public -o go-template='{{index .data "ca.crt" | base64decode}}' \
  | ssh $SERVER 'cat > /opt/replaicedesk/fluent-bit/ca.crt'
```

On the server, add the password from the secret manager to `.env` (root-only, like the database password):

```sh
cd /opt/replaicedesk
echo "FLUENTBIT_ES_PASSWORD=$(aws secretsmanager get-secret-value --secret-id logging/fluentbit-replaicedesk --query SecretString --output text)" >> .env
docker compose up -d
```

`up -d` recreates the four containers once so they pick up the new log options (a few seconds of
downtime), then starts `replaicedesk_fluent_bit`. Lines written before this moment are not collected.

## Check

```sh
docker compose ps fluent-bit                                   # running
docker compose logs --tail 20 fluent-bit | grep -iE 'error|warn'
```

In Kibana Dev Tools:

```
GET logs-replaicedesk/_search?size=0
{ "aggs": { "container": { "terms": { "field": "container" },
            "aggs": { "level": { "terms": { "field": "level" } } } } } }

GET logs-replaicedesk/_search?size=3&sort=@timestamp:desc&q=container:libredesk_app
```

`libredesk_app` lines have `level` and `message` as separate fields, not one raw string.

## Changing settings later

| Change | Where |
| --- | --- |
| Identity (cluster, env, host) | `LOG_*` in `docker-compose.override.yml`, then `docker compose up -d fluent-bit` |
| Another logfmt container | `LOGFMT_CONTAINERS` regex, e.g. `^(libredesk_app|worker)$` |
| A new container in the compose file | Give it `logging: *logging` in the override |
| Log file rotation | `max-size` / `max-file` in `x-logging` |

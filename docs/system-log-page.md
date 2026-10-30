# Replaice Desk System log page: reading central logs (Phase 8)

For the developers of the System log page (Admin → Teams → System log) in the ReplaiceDesk repo. Today the
page shows Replaice Desk's own recent warnings and errors from memory. With this change it shows the stored
logs of **every project** (tribe, Replaice Desk and any project onboarded later) from Elasticsearch, grouped
by project, and nothing is lost on refresh or restart.

All requests below were run against the platform with the page's real read-only user and return what is
shown.

## Connection

| Setting | Value | Source |
| --- | --- | --- |
| URL | `https://<ES_PRIVATE_DNS>:9200` | Private load balancer, reachable from the Replaice Desk server |
| User | `replaicedesk-syslog` | Role `logs_reader`: read `logs-*` and `observability-projects`, cannot write or delete |
| Password | from the secret manager (`logging/replaicedesk-syslog`) | Never in the repo |
| CA certificate | Elasticsearch's CA (`logs-es-http-certs-public`, key `ca.crt`) | Verify TLS with it; do not skip verification |

Suggested config (`config.toml`, values filled at deploy time from the secret manager):

```toml
[logs.elasticsearch]
enabled  = true
url      = "https://<ES_PRIVATE_DNS>:9200"
username = "replaicedesk-syslog"
password = ""            # from the secret manager
ca_file  = "/libredesk/es-ca.crt"
```

The backend talks to Elasticsearch; the browser never does.

## Data model

- One data stream per project: `logs-<project>`. Query `logs-*` for all projects.
- Fields on every line: `@timestamp`, `project`, `cluster`, `env`, `service`, `level`
  (`debug|info|warn|error|fatal`), `message`. Often: `request_id`, `caller`, `error`. Kubernetes lines also
  carry `kubernetes.pod_name`, `kubernetes.namespace_name`; Docker-host lines carry `host`, `container`.
  Lines that are not structured keep their text in `log` instead of `message`.
- Project registry, one document per project: index `observability-projects`, fields `project`,
  `display_name`, `data_stream`, `retention`. Use `display_name` in the UI.

## Requests

### Project names for the UI

```
GET observability-projects/_search?size=100
→ {"project":"tribe","display_name":"Tribe","data_stream":"logs-tribe","retention":"10d"}, ...
```

### Filter dropdowns (values seen in the chosen time range)

```
POST logs-*/_search
{ "size": 0,
  "query": { "range": { "@timestamp": { "gte": "now-24h" } } },
  "aggs": { "project": { "terms": { "field": "project", "size": 100 } },
            "cluster": { "terms": { "field": "cluster", "size": 200 } },
            "service": { "terms": { "field": "service", "size": 500 } },
            "level":   { "terms": { "field": "level",   "size": 10 } } } }
```

Narrow `cluster` and `service` by adding the chosen project to the query.

### Log table, newest first, with "load older"

Open a point in time once per table view, then page with `search_after`:

```
POST logs-*/_pit?keep_alive=2m            → { "id": "<pit>" }

POST _search
{ "size": 100,
  "pit": { "id": "<pit>", "keep_alive": "2m" },
  "sort": [ { "@timestamp": { "order": "desc", "format": "strict_date_optional_time_nanos" } } ],
  "_source": ["@timestamp","project","cluster","service","kubernetes.pod_name","host","level","message","log","request_id"],
  "query": { "bool": {
    "filter": [ { "range": { "@timestamp": { "gte": "now-1h" } } },
                { "terms": { "project": ["tribe"] } },
                { "terms": { "level": ["error","fatal"] } } ],
    "must":   [ { "simple_query_string": { "query": "<search box>", "fields": ["message","log","error"],
                                           "default_operator": "and" } } ] } } }
```

Leave out filters that are not set. For "load older", send the same body plus
`"search_after": <sort of the last row>`. Close the PIT when the user leaves (`DELETE _pit {"id": ...}`).
Use `simple_query_string`, never `query_string`, for the search box: it never fails on user input.

### Live mode

Every 5 seconds, ask for lines newer than the newest one shown, oldest first, and prepend them:

```
POST logs-*/_search
{ "size": 500, "sort": [ { "@timestamp": "asc" } ],
  "query": { "bool": { "filter": [ { "range": { "@timestamp": { "gt": "<newest @timestamp shown>" } } },
                                   ...same filters as the table... ] } } }
```

### Summary cards

```
POST logs-*/_search
{ "size": 0, "query": { ...same filters... },
  "aggs": { "level": { "terms": { "field": "level" } } } }
```

### Follow one request

Clicking a `request_id` shows that request across pods, services, clusters and projects:

```
POST logs-*/_search
{ "size": 200, "sort": [ { "@timestamp": "asc" } ], "query": { "term": { "request_id": "<id>" } } }
```

## Rules for the page

- Read-only. The user cannot write or delete; the page must not try.
- Admin only (permission `activity_logs:manage`): logs can contain customer data.
- Always send a time range (default last hour, maximum the project's retention) so queries stay fast.
- Cap `size` at 500 per request.
- Link out: "Open in Kibana" (`https://<KIBANA_HOST>/app/discover`) and "Open in Grafana"
  (`https://grafana.dev.archietech.co/d/logs-overview`) with the same filters, for deeper analysis.
- If Elasticsearch is unreachable, show a clear message and keep the page usable; never block the rest of
  the admin.

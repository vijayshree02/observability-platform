#!/usr/bin/env bash
# Sets up Grafana for logs. Safe to run again: every step creates or updates.
#
# Usage:
#   GRAFANA_URL=https://grafana.dev.archietech.co GRAFANA_TOKEN=<service account token> \
#   ES_URL=https://<ES_PRIVATE_DNS>:9200 ES_CACERT=<ca.crt> GRAFANA_PASSWORD=<ES password of user grafana> \
#   ./apply.sh tribe replaicedesk
#
# Creates:
#   data source   logs-elasticsearch     Elasticsearch, index logs-*, read-only user grafana
#   folder        logs                   "Logs"
#   dashboard     logs-overview          project / cluster / service / level / search filters
#   alert rule    logs-error-spike       more than $ERROR_THRESHOLD errors from one service in 5 minutes
#   contact point logs-slack             only when SLACK_WEBHOOK_URL is set; the rule then notifies it
#   dashboards    integrations/<project>/grafana/*.json for every project given (e.g. metrics dashboards)
#
# Environment:
#   GRAFANA_URL                                 required
#   GRAFANA_TOKEN, or GRAFANA_USER + GRAFANA_ADMIN_PASSWORD   required (Admin rights)
#   ES_URL, ES_CACERT, GRAFANA_PASSWORD         required: how Grafana reaches Elasticsearch
#   ERROR_THRESHOLD                             default 20
#   SLACK_WEBHOOK_URL                           optional
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../../.. && pwd)

: "${GRAFANA_URL:?set GRAFANA_URL}"
: "${ES_URL:?set ES_URL}"
: "${ES_CACERT:?set ES_CACERT (file with Elasticsearch CA certificate)}"
: "${GRAFANA_PASSWORD:?set GRAFANA_PASSWORD (Elasticsearch password of user grafana)}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-20}"

curl_opts=(-sS -H 'Content-Type: application/json' -H 'X-Disable-Provenance: true')
if [ -n "${GRAFANA_TOKEN:-}" ]; then
  curl_opts+=(-H "Authorization: Bearer $GRAFANA_TOKEN")
else
  : "${GRAFANA_USER:?set GRAFANA_TOKEN, or GRAFANA_USER and GRAFANA_ADMIN_PASSWORD}"
  : "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD}"
  curl_opts+=(-u "$GRAFANA_USER:$GRAFANA_ADMIN_PASSWORD")
fi

# gf <method> <path> [body]: fails the script on any non-2xx answer.
gf() {
  local method=$1 path=$2 body=${3:-} out code
  out=$(mktemp)
  code=$(curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' -X "$method" "$GRAFANA_URL$path" ${body:+--data-binary "$body"})
  if [[ $code != 2* ]]; then
    echo "FAILED $method $path ($code): $(cat "$out")" >&2
    rm -f "$out"
    exit 1
  fi
  rm -f "$out"
  echo "ok     $method $path ($code)"
}

exists() { # exists <path>: true if GET returns 200
  [ "$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "$GRAFANA_URL$1")" = 200 ]
}

render() { # render <file> NAME value ...: fills __NAME__ placeholders
  local text
  text=$(cat "$1")
  shift
  while [ "$#" -gt 0 ]; do
    text=${text//__$1__/$2}
    shift 2
  done
  printf '%s' "$text"
}

json_escape() { # json_escape <text>: escapes \ " and newlines for a JSON string
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "${s//$'\n'/\\n}"
}

dashboard_body() { # dashboard_body <file>: wraps a dashboard JSON for /api/dashboards/db
  printf '{"dashboard":%s,"folderUid":"logs","overwrite":true,"message":"observability-platform"}' "$(cat "$1")"
}

for project in "$@"; do
  if [[ ! $project =~ ^[a-z0-9]+$ ]]; then
    echo "invalid project name '$project': lowercase letters and digits only" >&2
    exit 1
  fi
done

echo "== Data source"
ds=$(render datasource.json ES_URL "$ES_URL" PASSWORD "$(json_escape "$GRAFANA_PASSWORD")" CA_CERT "$(json_escape "$(cat "$ES_CACERT")")")
if exists /api/datasources/uid/logs-elasticsearch; then
  gf PUT /api/datasources/uid/logs-elasticsearch "$ds"
else
  gf POST /api/datasources "$ds"
fi

echo "== Folder and dashboard"
if ! exists /api/folders/logs; then
  gf POST /api/folders '{"uid":"logs","title":"Logs"}'
fi
gf POST /api/dashboards/db "$(dashboard_body dashboards/logs-overview.json)"

echo "== Alerting"
rule=$(render alerting/error-spike.json THRESHOLD "$ERROR_THRESHOLD")
slack_exists() {
  curl "${curl_opts[@]}" "$GRAFANA_URL/api/v1/provisioning/contact-points" | grep -q '"uid":"logs-slack"'
}
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  cp=$(render alerting/contact-point.json SLACK_WEBHOOK_URL "$SLACK_WEBHOOK_URL")
  if slack_exists; then
    gf PUT /api/v1/provisioning/contact-points/logs-slack "$cp"
  else
    gf POST /api/v1/provisioning/contact-points "$cp"
  fi
fi
# Once the Slack contact point exists, the rule always notifies it (also on runs without SLACK_WEBHOOK_URL).
if slack_exists; then
  rule="${rule%\}},\"notification_settings\":{\"receiver\":\"logs-slack\"}}"
else
  echo "note   no Slack contact point yet (set SLACK_WEBHOOK_URL): the rule uses Grafana's notification policies"
fi
if exists /api/v1/provisioning/alert-rules/logs-error-spike; then
  gf PUT /api/v1/provisioning/alert-rules/logs-error-spike "$rule"
else
  gf POST /api/v1/provisioning/alert-rules "$rule"
fi

echo "== Project dashboards"
for project in "$@"; do
  for file in "$REPO_ROOT/integrations/$project/grafana/"*.json; do
    [ -e "$file" ] || continue
    gf POST /api/dashboards/db "$(dashboard_body "$file")"
  done
done

echo "Done."

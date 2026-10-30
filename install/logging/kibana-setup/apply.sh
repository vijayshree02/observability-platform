#!/usr/bin/env bash
# Sets up Kibana for every project's logs. Safe to run again: every step creates or updates.
#
# Usage:
#   KB_URL=https://<kibana-host> ES_PASSWORD=<elastic password> ./apply.sh tribe replaicedesk
#
# Per project <p> (display name from integrations/<p>/project.yaml if present):
#   data view       logs-<p>                  "<Display name>"
#   saved search    logs-<p>-errors           "<Display name>: errors"
#   role            logs_viewer_<p>           read-only Kibana + logs-<p> only (assign to that team)
#   alert rule      logs-<p>-error-spike      more than $ERROR_THRESHOLD errors from one service in 5 minutes
# Shared:
#   data view       logs-all                  "All projects" (logs-*)
#   saved search    logs-all-request-trace    "All projects: request trace"
#   role            logs_viewer_all           read-only Kibana + all projects
#
# Environment:
#   KB_URL, ES_PASSWORD     required (ES_USER defaults to elastic)
#   KB_CACERT               CA file for Kibana's certificate, if it is not publicly trusted
#   ERROR_THRESHOLD         errors per service in 5 minutes before an alert (default 20)
#   SLACK_WEBHOOK_URL       if set and the Elastic licence allows Slack (Gold or higher), alerts are also
#                           sent there. On the free Basic licence, Slack alerts come from Grafana instead.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../../.. && pwd)

: "${KB_URL:?set KB_URL}"
: "${ES_PASSWORD:?set ES_PASSWORD}"
ES_USER="${ES_USER:-elastic}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-20}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <project> ..." >&2
  exit 1
fi

curl_opts=(-sS -u "$ES_USER:$ES_PASSWORD" -H 'Content-Type: application/json' -H 'kbn-xsrf: observability-platform')
if [ -n "${KB_CACERT:-}" ]; then
  curl_opts+=(--cacert "$KB_CACERT")
fi

# kb <method> <path> [body]: fails the script on any non-2xx answer.
kb() {
  local method=$1 path=$2 body=${3:-} out code
  out=$(mktemp)
  code=$(curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' -X "$method" "$KB_URL$path" ${body:+--data-binary "$body"})
  if [[ $code != 2* ]]; then
    echo "FAILED $method $path ($code): $(cat "$out")" >&2
    rm -f "$out"
    exit 1
  fi
  rm -f "$out"
  echo "ok     $method $path ($code)"
}

kb_get() { # kb_get <path>: prints the body, or nothing on 404
  curl "${curl_opts[@]}" -f "$KB_URL$1" 2>/dev/null || true
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

display_name() { # display_name <project>: from integrations/<project>/project.yaml, else the project name
  local file="$REPO_ROOT/integrations/$1/project.yaml" name=""
  if [ -f "$file" ]; then
    name=$(sed -n 's/^display_name:[[:space:]]*//p' "$file" | sed 's/[[:space:]]*#.*$//; s/^"\(.*\)"$/\1/')
  fi
  printf '%s' "${name:-$1}"
}

# A Slack connector is only possible on a Gold or higher Elastic licence.
connector_id=""
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  if kb_get /api/actions/connector_types | grep -q '"id":".slack"[^}]*"enabled_in_license":true'; then
    if [ -z "$(kb_get /api/actions/connector/logs-slack)" ]; then
      kb POST /api/actions/connector/logs-slack \
        "{\"name\":\"Logs Slack\",\"connector_type_id\":\".slack\",\"secrets\":{\"webhookUrl\":\"$SLACK_WEBHOOK_URL\"}}"
    fi
    connector_id=logs-slack
  else
    echo "note   Slack connector needs an Elastic Gold licence; Kibana rules run without notifications (use Grafana for Slack)"
  fi
fi

actions='[]'
if [ -n "$connector_id" ]; then
  actions=$(render rules/slack-action.json CONNECTOR "$connector_id")
fi

# put_rule <id> <body without rule_type_id/consumer> <rule_type_id>: create or update an alert rule.
put_rule() {
  local id=$1 body=$2 type=$3
  if [ -n "$(kb_get "/api/alerting/rule/$id")" ]; then
    kb PUT "/api/alerting/rule/$id" "$body"
  else
    kb POST "/api/alerting/rule/$id" "${body%\}},\"rule_type_id\":\"$type\",\"consumer\":\"stackAlerts\"}"
  fi
}

echo "== Shared"
kb POST /api/data_views/data_view "$(render data-views/data-view.json ID logs-all TITLE 'logs-*' NAME 'All projects')"
kb POST "/api/saved_objects/search/logs-all-request-trace?overwrite=true" "$(cat searches/request-trace.json)"
kb PUT /api/security/role/logs_viewer_all "$(render roles/logs-viewer.json INDEX 'logs-*' NAME 'All projects')"

for project in "$@"; do
  if [[ ! $project =~ ^[a-z0-9]+$ ]]; then
    echo "invalid project name '$project': lowercase letters and digits only" >&2
    exit 1
  fi
  name=$(display_name "$project")
  echo "== Project $project ($name)"
  kb POST /api/data_views/data_view "$(render data-views/data-view.json ID "logs-$project" TITLE "logs-$project" NAME "$name")"
  kb POST "/api/saved_objects/search/logs-$project-errors?overwrite=true" \
    "$(render searches/errors.json PROJECT "$project" NAME "$name")"
  kb PUT "/api/security/role/logs_viewer_$project" "$(render roles/logs-viewer.json INDEX "logs-$project" NAME "$name")"
  put_rule "logs-$project-error-spike" \
    "$(render rules/error-spike.json PROJECT "$project" NAME "$name" THRESHOLD "$ERROR_THRESHOLD" ACTIONS "$actions")" .es-query
done

echo "Done."

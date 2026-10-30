#!/usr/bin/env bash
# Sets up Elasticsearch for logs. Safe to run again: every step creates or updates.
#
# Usage:
#   ES_URL=https://<es-host>:9200 ES_PASSWORD=<elastic password> ./apply.sh tribe replaicedesk:30d
#
# Arguments: one per project, as <project> or <project>:<retention>. Without :<retention>, the retention
# comes from integrations/<project>/project.yaml, else $RETENTION. The display name also comes from
# project.yaml; both are published in the index observability-projects for the Replaice Desk System log page.
#
# Environment:
#   ES_URL, ES_PASSWORD          required (ES_USER defaults to elastic)
#   ES_CACERT                    CA file for Elasticsearch's certificate; or ES_INSECURE=1 for local tests
#   RETENTION                    default retention for new projects (default 10d)
#   FLUENTBIT_PASSWORD_<PROJECT> creates/updates user fluentbit-<project> (e.g. FLUENTBIT_PASSWORD_TRIBE)
#   GRAFANA_PASSWORD             creates/updates user grafana (reader)
#   REPLAICEDESK_SYSLOG_PASSWORD creates/updates user replaicedesk-syslog (reader)
#   SNAPSHOT_BUCKET              registers the S3 snapshot repository and the daily snapshot policy
#
# Passwords come from the secret manager, never from files in this repo.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../../.. && pwd)

: "${ES_URL:?set ES_URL}"
: "${ES_PASSWORD:?set ES_PASSWORD}"
ES_USER="${ES_USER:-elastic}"
RETENTION="${RETENTION:-10d}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <project>[:<retention>] ..." >&2
  exit 1
fi

curl_opts=(-sS -u "$ES_USER:$ES_PASSWORD" -H 'Content-Type: application/json')
if [ -n "${ES_CACERT:-}" ]; then
  curl_opts+=(--cacert "$ES_CACERT")
elif [ "${ES_INSECURE:-}" = 1 ]; then
  curl_opts+=(-k)
fi

# es <method> <path> [body]: fails the script on any non-2xx answer.
es() {
  local method=$1 path=$2 body=${3:-} out code
  out=$(mktemp)
  code=$(curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' -X "$method" "$ES_URL$path" ${body:+--data-binary "$body"})
  if [[ $code != 2* ]]; then
    echo "FAILED $method $path ($code): $(cat "$out")" >&2
    rm -f "$out"
    exit 1
  fi
  rm -f "$out"
  echo "ok     $method $path ($code)"
}

# Fill __NAME__ placeholders in a JSON file: render <file> NAME value [NAME value ...]
render() {
  local text
  text=$(cat "$1")
  shift
  while [ "$#" -gt 0 ]; do
    text=${text//__$1__/$2}
    shift 2
  done
  printf '%s' "$text"
}

# exists <path>: true if GET returns 200
exists() {
  [ "$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "$ES_URL$1")" = 200 ]
}

# project_setting <project> <key>: a value from integrations/<project>/project.yaml, empty if missing
project_setting() {
  local file="$REPO_ROOT/integrations/$1/project.yaml"
  if [ -f "$file" ]; then
    sed -n "s/^$2:[[:space:]]*//p" "$file" | sed 's/[[:space:]]*#.*$//; s/^"\(.*\)"$/\1/'
  fi
}

user_body() { # user_body <password> <role>; escapes \ and " in the password for JSON
  local pw=${1//\\/\\\\}
  pw=${pw//\"/\\\"}
  printf '{"password":"%s","roles":["%s"]}' "$pw" "$2"
}

echo "== Ingest pipeline (normalises level, message, service)"
es PUT /_ingest/pipeline/logs-platform "$(cat ingest-pipelines/logs-platform.json)"

echo "== Shared template (default retention $RETENTION)"
es PUT /_index_template/logs-platform "$(render index-templates/logs-platform.json RETENTION "$RETENTION")"

echo "== Project registry (observability-projects)"
if ! exists /observability-projects; then
  es PUT /observability-projects "$(cat index-templates/observability-projects.json)"
fi

echo "== Reader role"
es PUT /_security/role/logs_reader "$(cat roles/logs_reader.json)"
if [ -n "${GRAFANA_PASSWORD:-}" ]; then
  es PUT /_security/user/grafana "$(user_body "$GRAFANA_PASSWORD" logs_reader)"
fi
if [ -n "${REPLAICEDESK_SYSLOG_PASSWORD:-}" ]; then
  es PUT /_security/user/replaicedesk-syslog "$(user_body "$REPLAICEDESK_SYSLOG_PASSWORD" logs_reader)"
fi

for arg in "$@"; do
  project=${arg%%:*}
  retention=$(project_setting "$project" retention)
  retention=${retention:-$RETENTION}
  if [[ $arg == *:* ]]; then
    retention=${arg#*:}
  fi
  if [[ ! $project =~ ^[a-z0-9]+$ ]]; then
    echo "invalid project name '$project': lowercase letters and digits only" >&2
    exit 1
  fi

  echo "== Project $project (retention $retention)"
  if ! exists "/_data_stream/logs-$project"; then
    es PUT "/_data_stream/logs-$project"
  fi
  es PUT "/_data_stream/logs-$project/_lifecycle" "{\"data_retention\":\"$retention\"}"
  es PUT "/_data_stream/logs-$project/_options" '{"failure_store":{"enabled":true}}'
  es PUT "/_security/role/logs_writer_$project" "$(render roles/logs_writer.json PROJECT "$project")"
  display=$(project_setting "$project" display_name)
  es PUT "/observability-projects/_doc/$project?refresh=true" \
    "{\"project\":\"$project\",\"display_name\":\"${display:-$project}\",\"data_stream\":\"logs-$project\",\"retention\":\"$retention\"}"

  pw_var="FLUENTBIT_PASSWORD_${project^^}"
  if [ -n "${!pw_var:-}" ]; then
    es PUT "/_security/user/fluentbit-$project" "$(user_body "${!pw_var}" "logs_writer_$project")"
  fi
done

if [ -n "${SNAPSHOT_BUCKET:-}" ]; then
  echo "== Snapshots to s3://$SNAPSHOT_BUCKET"
  es PUT /_snapshot/logs-s3 "$(render snapshots/repository.json SNAPSHOT_BUCKET "$SNAPSHOT_BUCKET")"
  es PUT /_slm/policy/logs-daily "$(cat snapshots/slm-policy.json)"
else
  echo "== Snapshots skipped (SNAPSHOT_BUCKET not set)"
fi

echo "Done."

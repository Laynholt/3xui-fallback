#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SWATTER_EVENTS_TEST="${SWATTER_EVENTS_TEST:-0}"
[[ "$SWATTER_EVENTS_TEST" == 1 ]] || SWATTER_EVENTS_TEST=0

log_options=()
if [[ "$SWATTER_EVENTS_TEST" == 1 ]]; then
  log_options=(--log-driver local --log-opt mode=non-blocking --log-opt max-buffer-size=1m --log-opt max-size=10m --log-opt max-file=3)
fi
start_nginx "3xui-fallback-sensitive-test-${PANEL_HTTPS_PORT}-${SUBS_HTTPS_PORT}" \
  "${log_options[@]}" \
  -e "MOSQUITO_SWATTER_EVENTS=$SWATTER_EVENTS_TEST"

assert_sensitive_path_blocked() {
  local port="$1"
  local path="$2"
  local response="$TMP_DIR/response-${port}-${path//\//_}"
  local status

  status="$(fetch_path "$port" "$path" "$response")"
  if [[ "$status" == "200" ]] || grep -q "LEAKED_ENV_CANARY" "$response"; then
    echo "Sensitive path leaked through nginx: port=$port path=$path status=$status" >&2
    cat "$response" >&2
    return 1
  fi
}

assert_proxy_still_works() {
  local port="$1"
  local path="$2"
  local response="$TMP_DIR/proxy-${port}-${path//\//_}"
  local status

  status="$(fetch_path "$port" "$path" "$response")"
  if [[ "$status" != "200" ]]; then
    echo "Expected normal proxy path to return 200: port=$port path=$path status=$status" >&2
    cat "$response" >&2
    return 1
  fi
  grep -q "LEAKED_ENV_CANARY" "$response"
}

assert_sensitive_path_blocked "$PANEL_HTTPS_PORT" "/.env"
assert_sensitive_path_blocked "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/.env"
assert_sensitive_path_blocked "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/.git/config"
assert_sensitive_path_blocked "$SUBS_HTTPS_PORT" "/.env"
assert_sensitive_path_blocked "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/.env"
assert_sensitive_path_blocked "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/.git/config"

assert_proxy_still_works "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health"
assert_proxy_still_works "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/health"

if [[ "$SWATTER_EVENTS_TEST" == 1 ]]; then
  status="$(fetch_path "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/swatter-token-canary?key=swatter-query-canary" "$TMP_DIR/swatter-response")"
  [[ "$status" == 200 ]]
  if [[ -n "$SUBS_JSON_PATH_PREFIX" ]]; then
    status="$(fetch_path "$SUBS_HTTPS_PORT" "$SUBS_JSON_PATH_PREFIX/swatter-token-canary" "$TMP_DIR/swatter-json-response")"
    [[ "$status" == 200 ]]
  fi
  status="$(curl -ksS -X SWATTERCANARY -H "Host: $SITE_DOMAIN" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PANEL_HTTPS_PORT/unknown")"
  [[ "$status" == 404 ]]
  # Each POST marker is sent to only one listener; error_page must preserve POST.
  status="$(curl -ksS -X POST -H "Host: $SITE_DOMAIN" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PANEL_HTTPS_PORT/.env")"
  [[ "$status" == 404 ]]
  status="$(curl -ksS -X POST -H "Host: $SITE_DOMAIN" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$SUBS_HTTPS_PORT/.git/config?key=swatter-query-canary")"
  [[ "$status" == 404 ]]
fi

read_swatter_logs() {
  container_stdout="$(docker exec "$NGINX_CONTAINER_ID" cat /var/log/swatter/http.jsonl)"
  swatter_jsonl="$(grep -F '{"schema":"moskit.http.v1",' <<< "$container_stdout" || true)"
}

if [[ "$SWATTER_EVENTS_TEST" == 1 ]]; then
  expected=(
    '"uri":"/.env","status":404'
    '"method":"GET","uri":"/.git/config","status":404'
    '"uri":"/_subscription","status":200'
    '"method":"OTHER","uri":"/_other","status":404'
    '"method":"POST","uri":"/.env","status":404'
    '"method":"POST","uri":"/.git/config","status":404'
  )
  # Docker nonblocking delivery can lag behind the HTTP response.
  for _ in {1..50}; do
    read_swatter_logs
    missing=()
    for record in "${expected[@]}"; do
      grep -Fq "$record" <<< "$swatter_jsonl" || missing+=("$record")
    done
    [[ "${#missing[@]}" == 0 ]] && break
    sleep 0.1
  done
  if [[ "${#missing[@]}" != 0 ]]; then
    printf 'Missing Swatter record: %s\n' "${missing[@]}" >&2
    exit 1
  fi
  if grep -Fq 'swatter-token-canary' <<< "$swatter_jsonl" || grep -Fq 'swatter-query-canary' <<< "$swatter_jsonl"; then
    echo 'Swatter log contains a raw path or query' >&2
    exit 1
  fi
  # An unredacted (public) record would carry only the hash of the raw token path.
  if [[ -n "$SUBS_JSON_PATH_PREFIX" ]]; then
    raw_hash="$(printf '%s' "$SUBS_JSON_PATH_PREFIX/swatter-token-canary" | sha256sum | cut -d' ' -f1)"
    if grep -Fq "$raw_hash" <<< "$swatter_jsonl" || [[ "$(grep -cF '"uri":"/_subscription","status":200' <<< "$swatter_jsonl")" -lt 2 ]]; then
      echo 'Swatter did not redact the SUBS_JSON_PATH_PREFIX token path' >&2
      exit 1
    fi
  fi
else
  sleep 0.5
  read_swatter_logs
  [[ -z "$swatter_jsonl" ]]
fi

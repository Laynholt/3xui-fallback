#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NAME="3xui-fallback-edge-test-${PANEL_HTTPS_PORT}-${SUBS_HTTPS_PORT}"
FAILURES=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

cidr_list_allows() {
  local status
  start_nginx "$NAME" -e "PANEL_ALLOWED_CIDR=10.9.9.0/24 127.0.0.1/32" || return 1
  status="$(fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health" "$TMP_DIR/allows")"
  [[ "$status" == 200 ]] && grep -q LEAKED_ENV_CANARY "$TMP_DIR/allows"
}

cidr_list_denies() {
  local status
  start_nginx "$NAME" -e "PANEL_ALLOWED_CIDR=10.9.9.0/24 10.8.8.8" || return 1
  status="$(fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health" "$TMP_DIR/denies")"
  [[ "$status" == 404 ]] && ! grep -q LEAKED_ENV_CANARY "$TMP_DIR/denies"
}

cidr_rejects_injection() {
  local value err
  for value in "" "1.2.3.4; allow all" "1.2.3.4 ;" $'1.2.3.4\nallow all;'; do
    if err="$(render_only -e "PANEL_ALLOWED_CIDR=$value" 2>&1 >/dev/null)"; then
      echo "render accepted PANEL_ALLOWED_CIDR='$value'" >&2
      return 1
    fi
    if ! grep -q "bad PANEL_ALLOWED_CIDR" <<< "$err"; then
      echo "no bad PANEL_ALLOWED_CIDR error for '$value': $err" >&2
      return 1
    fi
  done
}

logs_to_stdout() {
  start_nginx "$NAME" || return 1
  fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health" /dev/null >/dev/null
  # Docker log delivery can lag behind the HTTP response.
  for _ in {1..30}; do
    docker logs "$NGINX_CONTAINER_ID" 2>/dev/null | grep -qF "$PANEL_PATH_PREFIX/health" && return 0
    sleep 0.1
  done
  return 1
}

# Response headers of a subs request; prints the status code.
fetch_subs_headers() {
  curl -ksS -H "Host: $SITE_DOMAIN" -D "$2" -o /dev/null -w '%{http_code}' \
    "https://127.0.0.1:$SUBS_HTTPS_PORT$1"
}

header_value() {
  awk -v name="$1" 'tolower($1) == name ":" { sub(/\r$/, ""); print $2 }' "$2"
}

subs_big_header() {
  local status value
  start_nginx "$NAME" || return 1
  status="$(fetch_subs_headers "$SUBS_PATH_PREFIX/bigheader" "$TMP_DIR/bigheader")"
  value="$(header_value per-app-proxy-list "$TMP_DIR/bigheader")"
  [[ "$status" == 200 && "${#value}" == 6000 ]] || {
    echo "status=$status Per-App-Proxy-List length=${#value}" >&2
    return 1
  }
  [[ "$(header_value x-seen-forwarded-prefix "$TMP_DIR/bigheader")" == "$SUBS_PATH_PREFIX" ]]
}

subs_json_prefix() {
  local status
  start_nginx "$NAME" -e SUBS_JSON_PATH_PREFIX=/json || return 1
  status="$(fetch_path "$SUBS_HTTPS_PORT" /json/health "$TMP_DIR/json")"
  [[ "$status" == 200 ]] && grep -q LEAKED_ENV_CANARY "$TMP_DIR/json" || return 1
  fetch_subs_headers /json/bigheader "$TMP_DIR/json-headers" >/dev/null
  [[ "$(header_value x-seen-forwarded-prefix "$TMP_DIR/json-headers")" == /json ]] || return 1
  status="$(fetch_path "$SUBS_HTTPS_PORT" /json/.env "$TMP_DIR/json-env")"
  [[ "$status" != 200 ]] && ! grep -q LEAKED_ENV_CANARY "$TMP_DIR/json-env"
}

subs_json_prefix_off() {
  local status
  start_nginx "$NAME" -e SUBS_JSON_PATH_PREFIX= || return 1
  status="$(fetch_path "$SUBS_HTTPS_PORT" /json/health "$TMP_DIR/json-off")"
  [[ "$status" == 404 ]] && ! grep -q LEAKED_ENV_CANARY "$TMP_DIR/json-off"
}

subs_json_prefix_bad() {
  local value err
  for value in /json/ json "$SUBS_PATH_PREFIX" "$SUBS_PATH_PREFIX/" $'/json\n/x' '/json;'; do
    if err="$(render_only -e "SUBS_JSON_PATH_PREFIX=$value" 2>&1 >/dev/null)"; then
      echo "render accepted SUBS_JSON_PATH_PREFIX='$value'" >&2
      return 1
    fi
    if ! grep -q "bad SUBS_JSON_PATH_PREFIX" <<< "$err"; then
      echo "no bad SUBS_JSON_PATH_PREFIX error for '$value': $err" >&2
      return 1
    fi
  done
}

sites_hooks() {
  local status
  mkdir -p "$TMP_DIR/sites/http" "$TMP_DIR/sites/subs"
  echo 'map $uri $edge_t { default 0; /hook 1; }' > "$TMP_DIR/sites/http/t.conf"
  echo 'location = /hook { return 200 "hook:$edge_t"; }' > "$TMP_DIR/sites/subs/t.conf"
  start_nginx "$NAME" -v "$TMP_DIR/sites:/etc/nginx/sites:ro" || return 1
  status="$(fetch_path "$SUBS_HTTPS_PORT" /hook "$TMP_DIR/hook")"
  [[ "$status" == 200 && "$(cat "$TMP_DIR/hook")" == hook:1 ]]
}

sites_absent() {
  local status
  start_nginx "$NAME" || return 1
  status="$(fetch_path "$SUBS_HTTPS_PORT" /hook "$TMP_DIR/hook-absent")"
  [[ "$status" == 404 ]]
}

# Status of a panel request; response headers go to $2, the body to $3.
fetch_panel() {
  local path="$1" headers="$2" body="$3"
  shift 3
  curl -ksS -H "Host: $SITE_DOMAIN" -D "$headers" -o "$body" -w '%{http_code}' "$@" \
    "https://127.0.0.1:$PANEL_HTTPS_PORT$path"
}

upstream_got() {
  grep -qxF "$1" "$UPSTREAM_PATHS"
}

sponsors_hidden() {
  local status type
  start_nginx "$NAME" -e PANEL_HIDE_SPONSORS=1 || return 1
  : > "$UPSTREAM_PATHS"
  status="$(fetch_panel "$PANEL_PATH_PREFIX/sponsors" "$TMP_DIR/sponsors-headers" "$TMP_DIR/sponsors")"
  type="$(header_value content-type "$TMP_DIR/sponsors-headers")"
  if [[ "$status" != 200 || "$type" != application/json ]] \
    || ! printf '%s' '{"success":true,"obj":[]}' | cmp -s - "$TMP_DIR/sponsors"; then
    echo "status=$status content-type=$type body=$(head -c 200 "$TMP_DIR/sponsors")" >&2
    return 1
  fi
  # The logo route stays proxied; this also proves the mock records paths.
  fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/sponsors/logo/x" /dev/null >/dev/null
  upstream_got "$PANEL_PATH_PREFIX/sponsors/logo/x" && ! upstream_got "$PANEL_PATH_PREFIX/sponsors"
}

# Review Focus 1: a denied address gets the same 404 as any panel path, never the stub.
sponsors_hidden_denied() {
  local status
  start_nginx "$NAME" -e PANEL_HIDE_SPONSORS=1 -e PANEL_ALLOWED_CIDR=10.8.8.8 || return 1
  status="$(fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/sponsors" "$TMP_DIR/sponsors-denied")"
  [[ "$status" == 404 ]] && cmp -s "$ROOT_DIR/html/404.html" "$TMP_DIR/sponsors-denied"
}

# Anything but 1 is off, and the value never reaches the config verbatim.
sponsors_flag_normalized() {
  local status
  start_nginx "$NAME" -e 'PANEL_HIDE_SPONSORS=1";' || return 1
  status="$(fetch_path "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/sponsors" "$TMP_DIR/sponsors-garbage")"
  [[ "$status" == 200 ]] && grep -q LEAKED_ENV_CANARY "$TMP_DIR/sponsors-garbage"
}

panel_websocket_still_proxied() {
  local status
  start_nginx "$NAME" -e PANEL_HIDE_SPONSORS=1 || return 1
  status="$(fetch_panel "$PANEL_PATH_PREFIX/ws" "$TMP_DIR/ws-headers" /dev/null \
    --http1.1 -H 'Upgrade: websocket' -H 'Connection: Upgrade')"
  [[ "$status" == 200 && "$(header_value x-seen-upgrade "$TMP_DIR/ws-headers")" == websocket ]]
}

for test_name in cidr_list_allows cidr_list_denies cidr_rejects_injection logs_to_stdout \
  subs_big_header subs_json_prefix subs_json_prefix_off subs_json_prefix_bad sites_hooks sites_absent \
  sponsors_hidden sponsors_hidden_denied sponsors_flag_normalized panel_websocket_still_proxied; do
  if "$test_name"; then
    echo "PASS: $test_name"
  else
    fail "$test_name"
  fi
done
stop_nginx

if [[ "$FAILURES" -ne 0 ]]; then
  echo "$FAILURES edge option failure(s)" >&2
  exit 1
fi

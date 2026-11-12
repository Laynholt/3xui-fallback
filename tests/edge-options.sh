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
  for value in "" "1.2.3.4; allow all" "1.2.3.4 ;"; do
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

for test_name in cidr_list_allows cidr_list_denies cidr_rejects_injection logs_to_stdout; do
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

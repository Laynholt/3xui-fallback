#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.tmp"
export TMPDIR="$ROOT_DIR/.tmp" TEMP="$ROOT_DIR/.tmp" TMP="$ROOT_DIR/.tmp"
TMP_DIR="$(mktemp -d)"
SWATTER_EVENTS_TEST="${SWATTER_EVENTS_TEST:-0}"
[[ "$SWATTER_EVENTS_TEST" == 1 ]] || SWATTER_EVENTS_TEST=0
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30.6-alpine@sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311}"
SITE_DOMAIN="${SITE_DOMAIN:-example.test}"
PANEL_ALLOWED_CIDR="${PANEL_ALLOWED_CIDR:-127.0.0.1/32}"
PANEL_PATH_PREFIX="${PANEL_PATH_PREFIX:-/panel}"
SUBS_PATH_PREFIX="${SUBS_PATH_PREFIX:-/subs}"
PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-$((28000 + RANDOM % 1000))}"
SUBS_HTTPS_PORT="${SUBS_HTTPS_PORT:-$((29000 + RANDOM % 1000))}"
UPSTREAM_PORT="${TEST_UPSTREAM_PORT:-$((30000 + RANDOM % 1000))}"
NGINX_CONTAINER="3xui-fallback-sensitive-test-${PANEL_HTTPS_PORT}-${SUBS_HTTPS_PORT}"

cleanup() {
  if [[ -n "${NGINX_CONTAINER_ID:-}" ]]; then
    docker rm -f "$NGINX_CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${UPSTREAM_PID:-}" ]]; then
    kill "$UPSTREAM_PID" >/dev/null 2>&1 || true
    wait "$UPSTREAM_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days 1 \
  -nodes \
  -keyout "$TMP_DIR/privkey.pem" \
  -out "$TMP_DIR/fullchain.pem" \
  -subj "/CN=$SITE_DOMAIN" \
  -addext "subjectAltName=DNS:$SITE_DOMAIN" \
  >/dev/null 2>&1

python3 - "$UPSTREAM_PORT" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"LEAKED_ENV_CANARY=1\n")

    def log_message(self, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
UPSTREAM_PID=$!

upstream_ready=0
for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:$UPSTREAM_PORT/health" >/dev/null 2>&1; then
    upstream_ready=1
    break
  fi
  sleep 0.1
done
if [[ "$upstream_ready" != "1" ]]; then
  echo "Mock upstream did not become ready on port $UPSTREAM_PORT" >&2
  exit 1
fi

log_options=()
if [[ "$SWATTER_EVENTS_TEST" == 1 ]]; then
  log_options=(--log-driver local --log-opt mode=non-blocking --log-opt max-buffer-size=1m --log-opt max-size=10m --log-opt max-file=3)
fi
NGINX_CONTAINER_ID="$(docker run \
  -d \
  --rm \
  --name "$NGINX_CONTAINER" \
  --network host \
  "${log_options[@]}" \
  -e "MOSQUITO_SWATTER_EVENTS=$SWATTER_EVENTS_TEST" \
  -e "SITE_DOMAIN=$SITE_DOMAIN" \
  -e "PANEL_HTTPS_PORT=$PANEL_HTTPS_PORT" \
  -e "SUBS_HTTPS_PORT=$SUBS_HTTPS_PORT" \
  -e "PANEL_ALLOWED_CIDR=$PANEL_ALLOWED_CIDR" \
  -e "PANEL_PATH_PREFIX=$PANEL_PATH_PREFIX" \
  -e "SUBS_PATH_PREFIX=$SUBS_PATH_PREFIX" \
  -e "PANEL_BACKEND_SCHEME=http" \
  -e "PANEL_BACKEND_HOST=127.0.0.1" \
  -e "PANEL_BACKEND_PORT=$UPSTREAM_PORT" \
  -e "PANEL_BACKEND_TLS_NAME=127.0.0.1" \
  -e "PANEL_BACKEND_SSL_VERIFY=off" \
  -e "SUBS_BACKEND_SCHEME=http" \
  -e "SUBS_BACKEND_HOST=127.0.0.1" \
  -e "SUBS_BACKEND_PORT=$UPSTREAM_PORT" \
  -e "SUBS_BACKEND_TLS_NAME=127.0.0.1" \
  -e "SUBS_BACKEND_SSL_VERIFY=off" \
  -v "$ROOT_DIR/swatter.js:/etc/nginx/swatter.js:ro" \
  -v "$ROOT_DIR/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
  -v "$ROOT_DIR/html:/usr/share/nginx/html:ro" \
  -v "$TMP_DIR/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro" \
  -v "$TMP_DIR/privkey.pem:/etc/nginx/certs/privkey.pem:ro" \
  "$NGINX_IMAGE" \
  /bin/sh -c "mkdir -p /var/log/swatter; envsubst '\$MOSQUITO_SWATTER_EVENTS \$SITE_DOMAIN \$PANEL_HTTPS_PORT \$SUBS_HTTPS_PORT \$PANEL_ALLOWED_CIDR \$PANEL_PATH_PREFIX \$SUBS_PATH_PREFIX \$PANEL_BACKEND_SCHEME \$PANEL_BACKEND_HOST \$PANEL_BACKEND_PORT \$PANEL_BACKEND_TLS_NAME \$PANEL_BACKEND_SSL_VERIFY \$SUBS_BACKEND_SCHEME \$SUBS_BACKEND_HOST \$SUBS_BACKEND_PORT \$SUBS_BACKEND_TLS_NAME \$SUBS_BACKEND_SSL_VERIFY' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf && nginx -t && nginx -g 'daemon off;'" \
  )"

nginx_ready=0
for _ in {1..80}; do
  if curl -ksS -H "Host: $SITE_DOMAIN" "https://127.0.0.1:$PANEL_HTTPS_PORT/" >/dev/null 2>&1; then
    nginx_ready=1
    break
  fi
  sleep 0.1
done
if [[ "$nginx_ready" != "1" ]]; then
  echo "nginx test container did not become ready" >&2
  docker logs "$NGINX_CONTAINER_ID" >&2 || true
  exit 1
fi

fetch_path() {
  local port="$1"
  local path="$2"
  local output="$3"

  curl \
    -ksS \
    -H "Host: $SITE_DOMAIN" \
    -o "$output" \
    -w "%{http_code}" \
    "https://127.0.0.1:$port$path"
}

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
else
  sleep 0.5
  read_swatter_logs
  [[ -z "$swatter_jsonl" ]]
fi

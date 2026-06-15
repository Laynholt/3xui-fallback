#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284}"
SITE_DOMAIN="${SITE_DOMAIN:-example.test}"
PANEL_ALLOWED_CIDR="${PANEL_ALLOWED_CIDR:-127.0.0.1/32}"
PANEL_PATH_PREFIX="${PANEL_PATH_PREFIX:-/panel}"
SUBS_PATH_PREFIX="${SUBS_PATH_PREFIX:-/subs}"
PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-$((28000 + RANDOM % 1000))}"
SUBS_HTTPS_PORT="${SUBS_HTTPS_PORT:-$((29000 + RANDOM % 1000))}"
UPSTREAM_PORT="${TEST_UPSTREAM_PORT:-$((30000 + RANDOM % 1000))}"
NGINX_CONTAINER="3xui-fallback-sensitive-test-${PANEL_HTTPS_PORT}-${SUBS_HTTPS_PORT}"

cleanup() {
  docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
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

docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
docker run \
  -d \
  --rm \
  --name "$NGINX_CONTAINER" \
  --network host \
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
  -v "$ROOT_DIR/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
  -v "$ROOT_DIR/html:/usr/share/nginx/html:ro" \
  -v "$TMP_DIR/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro" \
  -v "$TMP_DIR/privkey.pem:/etc/nginx/certs/privkey.pem:ro" \
  "$NGINX_IMAGE" \
  /bin/sh -c "envsubst '\$SITE_DOMAIN \$PANEL_HTTPS_PORT \$SUBS_HTTPS_PORT \$PANEL_ALLOWED_CIDR \$PANEL_PATH_PREFIX \$SUBS_PATH_PREFIX \$PANEL_BACKEND_SCHEME \$PANEL_BACKEND_HOST \$PANEL_BACKEND_PORT \$PANEL_BACKEND_TLS_NAME \$PANEL_BACKEND_SSL_VERIFY \$SUBS_BACKEND_SCHEME \$SUBS_BACKEND_HOST \$SUBS_BACKEND_PORT \$SUBS_BACKEND_TLS_NAME \$SUBS_BACKEND_SSL_VERIFY' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf && nginx -t && nginx -g 'daemon off;'" \
  >/dev/null

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
  docker logs "$NGINX_CONTAINER" >&2 || true
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

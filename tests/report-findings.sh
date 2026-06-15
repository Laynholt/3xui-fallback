#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284}"
SITE_DOMAIN="${SITE_DOMAIN:-example.test}"
ATTACKER_HOST="${ATTACKER_HOST:-attacker.example}"
PANEL_ALLOWED_CIDR="${PANEL_ALLOWED_CIDR:-127.0.0.1/32}"
PANEL_PATH_PREFIX="${PANEL_PATH_PREFIX:-/panel}"
SUBS_PATH_PREFIX="${SUBS_PATH_PREFIX:-/subs}"
PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-$((28100 + RANDOM % 1000))}"
SUBS_HTTPS_PORT="${SUBS_HTTPS_PORT:-$((29100 + RANDOM % 1000))}"
UPSTREAM_PORT="${TEST_UPSTREAM_PORT:-$((30100 + RANDOM % 1000))}"
NGINX_CONTAINER="3xui-fallback-findings-test-${PANEL_HTTPS_PORT}-${SUBS_HTTPS_PORT}"
FAILURES=0

cleanup() {
  docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
  if [[ -n "${UPSTREAM_PID:-}" ]]; then
    kill "$UPSTREAM_PID" >/dev/null 2>&1 || true
    wait "$UPSTREAM_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days 1 \
  -nodes \
  -keyout "$TMP_DIR/frontend-privkey.pem" \
  -out "$TMP_DIR/frontend-fullchain.pem" \
  -subj "/CN=$SITE_DOMAIN" \
  -addext "subjectAltName=DNS:$SITE_DOMAIN" \
  >/dev/null 2>&1 || exit 1

render_config() {
  docker run \
    --rm \
    --network none \
    -e "SITE_DOMAIN=$SITE_DOMAIN" \
    -e "PANEL_HTTPS_PORT=$PANEL_HTTPS_PORT" \
    -e "SUBS_HTTPS_PORT=$SUBS_HTTPS_PORT" \
    -e "PANEL_ALLOWED_CIDR=$PANEL_ALLOWED_CIDR" \
    -e "PANEL_PATH_PREFIX=$PANEL_PATH_PREFIX" \
    -e "SUBS_PATH_PREFIX=$SUBS_PATH_PREFIX" \
    -e "PANEL_BACKEND_SCHEME=https" \
    -e "PANEL_BACKEND_HOST=panel-backend.test" \
    -e "PANEL_BACKEND_PORT=9443" \
    -e "PANEL_BACKEND_TLS_NAME=panel-backend.test" \
    -e "PANEL_BACKEND_SSL_VERIFY=on" \
    -e "SUBS_BACKEND_SCHEME=https" \
    -e "SUBS_BACKEND_HOST=subs-backend.test" \
    -e "SUBS_BACKEND_PORT=9444" \
    -e "SUBS_BACKEND_TLS_NAME=subs-backend.test" \
    -e "SUBS_BACKEND_SSL_VERIFY=on" \
    -v "$ROOT_DIR/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
    "$NGINX_IMAGE" \
    /bin/sh -c "envsubst '\$SITE_DOMAIN \$PANEL_HTTPS_PORT \$SUBS_HTTPS_PORT \$PANEL_ALLOWED_CIDR \$PANEL_PATH_PREFIX \$SUBS_PATH_PREFIX \$PANEL_BACKEND_SCHEME \$PANEL_BACKEND_HOST \$PANEL_BACKEND_PORT \$PANEL_BACKEND_TLS_NAME \$PANEL_BACKEND_SSL_VERIFY \$SUBS_BACKEND_SCHEME \$SUBS_BACKEND_HOST \$SUBS_BACKEND_PORT \$SUBS_BACKEND_TLS_NAME \$SUBS_BACKEND_SSL_VERIFY' < /etc/nginx/templates/nginx.conf.template" \
    > "$TMP_DIR/rendered-nginx.conf"
}

assert_deployment_image_pinned() {
  if grep -qE '^[[:space:]]*image:[[:space:]]+nginx:latest[[:space:]]*$' "$ROOT_DIR/docker-compose.yml"; then
    fail "docker-compose.yml still deploys floating nginx:latest"
  fi
  if ! grep -qE '^[[:space:]]*image:[[:space:]]+nginx:[^[:space:]]+@sha256:[0-9a-f]{64}[[:space:]]*$' "$ROOT_DIR/docker-compose.yml"; then
    fail "docker-compose.yml must pin nginx to an immutable sha256 digest"
  fi
}

assert_tls_name_defaults_to_backend_host() {
  if ! grep -q 'PANEL_BACKEND_TLS_NAME.*PANEL_BACKEND_HOST' "$ROOT_DIR/docker-compose.yml"; then
    fail "docker-compose.yml must default PANEL_BACKEND_TLS_NAME to PANEL_BACKEND_HOST for existing .env files"
  fi
  if ! grep -q 'SUBS_BACKEND_TLS_NAME.*SUBS_BACKEND_HOST' "$ROOT_DIR/docker-compose.yml"; then
    fail "docker-compose.yml must default SUBS_BACKEND_TLS_NAME to SUBS_BACKEND_HOST for existing .env files"
  fi
}

assert_static_tls_config() {
  render_config || {
    fail "could not render nginx config"
    return
  }

  if grep -q "proxy_ssl_verify off;" "$TMP_DIR/rendered-nginx.conf"; then
    fail "rendered config still disables upstream TLS verification"
  fi
  if [[ "$(grep -c "proxy_ssl_verify on;" "$TMP_DIR/rendered-nginx.conf")" -ne 2 ]]; then
    fail "rendered config must enable upstream TLS verification for panel and subscription backends"
  fi
  if [[ "$(grep -c "proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;" "$TMP_DIR/rendered-nginx.conf")" -ne 2 ]]; then
    fail "rendered config must use a trusted CA bundle for both upstream HTTPS backends"
  fi
  if grep -q 'proxy_ssl_name \$host;' "$TMP_DIR/rendered-nginx.conf"; then
    fail "rendered config still uses client Host as upstream TLS identity"
  fi
  if ! grep -q "proxy_ssl_name panel-backend.test;" "$TMP_DIR/rendered-nginx.conf"; then
    fail "panel upstream TLS identity must use PANEL_BACKEND_TLS_NAME"
  fi
  if ! grep -q "proxy_ssl_name subs-backend.test;" "$TMP_DIR/rendered-nginx.conf"; then
    fail "subscription upstream TLS identity must use SUBS_BACKEND_TLS_NAME"
  fi
}

assert_panel_access_gate_config() {
  render_config || {
    fail "could not render nginx config for panel access gate check"
    return
  }

  if ! awk \
    -v panel_location="location ${PANEL_PATH_PREFIX}/" \
    -v allowed_directive="allow ${PANEL_ALLOWED_CIDR};" '
    index($0, panel_location) { in_panel = 1 }
    in_panel && index($0, allowed_directive) { found_allow = 1 }
    in_panel && index($0, "deny all;") { found_deny = 1 }
    in_panel && /^        }/ { in_panel = 0 }
    END { exit !(found_allow && found_deny) }
  ' "$TMP_DIR/rendered-nginx.conf"; then
    fail "panel proxy location must include allow $PANEL_ALLOWED_CIDR and deny all"
  fi

  if awk \
    -v subs_location="location ${SUBS_PATH_PREFIX}/" '
    index($0, subs_location) { in_subs = 1 }
    in_subs && index($0, "deny all;") { found_deny = 1 }
    in_subs && /^        }/ { in_subs = 0 }
    END { exit !found_deny }
  ' "$TMP_DIR/rendered-nginx.conf"; then
    fail "subscription proxy location must not inherit the panel access gate"
  fi
}

assert_forwarded_for_sanitized() {
  render_config || {
    fail "could not render nginx config for X-Forwarded-For check"
    return
  }

  if grep -q 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' "$TMP_DIR/rendered-nginx.conf"; then
    fail "rendered config still preserves client-controlled X-Forwarded-For chains"
  fi
  if [[ "$(grep -c 'proxy_set_header X-Forwarded-For $remote_addr;' "$TMP_DIR/rendered-nginx.conf")" -ne 2 ]]; then
    fail "rendered config must rebuild X-Forwarded-For from remote_addr for panel and subscription backends"
  fi
}

start_http_upstream() {
  python3 - "$UPSTREAM_PORT" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "http://backend.internal/upstream-login")
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"UPSTREAM_HTTP_CANARY=1\n")

    def log_message(self, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
  UPSTREAM_PID=$!
}

start_tls_upstream() {
  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 1 \
    -nodes \
    -keyout "$TMP_DIR/upstream-privkey.pem" \
    -out "$TMP_DIR/upstream-fullchain.pem" \
    -subj "/CN=self-signed-upstream.invalid" \
    -addext "subjectAltName=DNS:self-signed-upstream.invalid" \
    >/dev/null 2>&1 || exit 1

  python3 - "$UPSTREAM_PORT" "$TMP_DIR/upstream-fullchain.pem" "$TMP_DIR/upstream-privkey.pem" <<'PY' &
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"UPSTREAM_TLS_CANARY=1\n")

    def log_message(self, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
  UPSTREAM_PID=$!
}

start_trusted_tls_upstream() {
  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 1 \
    -nodes \
    -keyout "$TMP_DIR/upstream-ca-key.pem" \
    -out "$TMP_DIR/upstream-ca.pem" \
    -subj "/CN=3xui-fallback-test-ca" \
    >/dev/null 2>&1 || exit 1

  openssl req \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$TMP_DIR/upstream-trusted-privkey.pem" \
    -out "$TMP_DIR/upstream-trusted.csr" \
    -subj "/CN=$SITE_DOMAIN" \
    -addext "subjectAltName=DNS:$SITE_DOMAIN" \
    >/dev/null 2>&1 || exit 1

  openssl x509 \
    -req \
    -in "$TMP_DIR/upstream-trusted.csr" \
    -CA "$TMP_DIR/upstream-ca.pem" \
    -CAkey "$TMP_DIR/upstream-ca-key.pem" \
    -CAcreateserial \
    -sha256 \
    -days 1 \
    -copy_extensions copy \
    -out "$TMP_DIR/upstream-trusted-fullchain.pem" \
    >/dev/null 2>&1 || exit 1

  python3 - "$UPSTREAM_PORT" "$TMP_DIR/upstream-trusted-fullchain.pem" "$TMP_DIR/upstream-trusted-privkey.pem" <<'PY' &
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"UPSTREAM_TLS_CANARY=1\n")

    def log_message(self, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
  UPSTREAM_PID=$!
}

wait_for_upstream() {
  local scheme="$1"
  local curl_flags=(-fsS)
  if [[ "$scheme" == "https" ]]; then
    curl_flags=(-kfsS)
  fi

  for _ in {1..50}; do
    if curl "${curl_flags[@]}" "$scheme://127.0.0.1:$UPSTREAM_PORT/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  fail "mock $scheme upstream did not become ready on port $UPSTREAM_PORT"
  return 1
}

stop_upstream() {
  if [[ -n "${UPSTREAM_PID:-}" ]]; then
    kill "$UPSTREAM_PID" >/dev/null 2>&1 || true
    wait "$UPSTREAM_PID" >/dev/null 2>&1 || true
    unset UPSTREAM_PID
  fi
}

start_nginx() {
  local backend_scheme="$1"
  local backend_tls_name="${2:-127.0.0.1}"
  local trusted_ca="${3:-}"
  local ssl_verify="${4:-on}"
  local ca_volume=()

  if [[ -n "$trusted_ca" ]]; then
    ca_volume=(-v "$trusted_ca:/etc/ssl/certs/ca-certificates.crt:ro")
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
    -e "PANEL_BACKEND_SCHEME=$backend_scheme" \
    -e "PANEL_BACKEND_HOST=127.0.0.1" \
    -e "PANEL_BACKEND_PORT=$UPSTREAM_PORT" \
    -e "PANEL_BACKEND_TLS_NAME=$backend_tls_name" \
    -e "PANEL_BACKEND_SSL_VERIFY=$ssl_verify" \
    -e "SUBS_BACKEND_SCHEME=$backend_scheme" \
    -e "SUBS_BACKEND_HOST=127.0.0.1" \
    -e "SUBS_BACKEND_PORT=$UPSTREAM_PORT" \
    -e "SUBS_BACKEND_TLS_NAME=$backend_tls_name" \
    -e "SUBS_BACKEND_SSL_VERIFY=$ssl_verify" \
    -v "$ROOT_DIR/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
    -v "$ROOT_DIR/html:/usr/share/nginx/html:ro" \
    -v "$TMP_DIR/frontend-fullchain.pem:/etc/nginx/certs/fullchain.pem:ro" \
    -v "$TMP_DIR/frontend-privkey.pem:/etc/nginx/certs/privkey.pem:ro" \
    "${ca_volume[@]}" \
    "$NGINX_IMAGE" \
    /bin/sh -c "envsubst '\$SITE_DOMAIN \$PANEL_HTTPS_PORT \$SUBS_HTTPS_PORT \$PANEL_ALLOWED_CIDR \$PANEL_PATH_PREFIX \$SUBS_PATH_PREFIX \$PANEL_BACKEND_SCHEME \$PANEL_BACKEND_HOST \$PANEL_BACKEND_PORT \$PANEL_BACKEND_TLS_NAME \$PANEL_BACKEND_SSL_VERIFY \$SUBS_BACKEND_SCHEME \$SUBS_BACKEND_HOST \$SUBS_BACKEND_PORT \$SUBS_BACKEND_TLS_NAME \$SUBS_BACKEND_SSL_VERIFY' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf && nginx -t && nginx -g 'daemon off;'" \
    >/dev/null || {
      fail "nginx container failed to start"
      return 1
    }

  for _ in {1..80}; do
    if curl -ksS -H "Host: $SITE_DOMAIN" "https://127.0.0.1:$PANEL_HTTPS_PORT/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  fail "nginx test container did not become ready"
  docker logs "$NGINX_CONTAINER" >&2 || true
  return 1
}

stop_nginx() {
  docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
}

request_headers() {
  local port="$1"
  local host="$2"
  local path="$3"
  local headers="$4"

  curl \
    -ksS \
    -D "$headers" \
    -o "$TMP_DIR/body-${port}-${host}-${path//\//_}" \
    -w "%{http_code}" \
    -H "Host: $host" \
    "https://127.0.0.1:$port$path" \
    2>/dev/null || true
}

assert_attacker_host_not_reflected() {
  local port="$1"
  local path="$2"
  local headers="$TMP_DIR/headers-${port}-${path//\//_}"
  local status

  status="$(request_headers "$port" "$ATTACKER_HOST" "$path" "$headers")"
  if [[ "$status" =~ ^[23] ]]; then
    fail "attacker Host was accepted with status=$status for port=$port path=$path"
  fi
  if grep -qi "location: .*${ATTACKER_HOST}" "$headers"; then
    fail "attacker Host was reflected into Location for port=$port path=$path"
  fi
}

assert_canonical_redirect() {
  local port="$1"
  local path="$2"
  local headers="$TMP_DIR/headers-canonical-${port}-${path//\//_}"
  local expected="https://${SITE_DOMAIN}:${port}/upstream-login"

  request_headers "$port" "$SITE_DOMAIN" "$path" "$headers" >/dev/null
  if ! grep -qi "location: ${expected}" "$headers"; then
    fail "expected canonical Location $expected for port=$port path=$path"
    cat "$headers" >&2
  fi
}

assert_http_proxy_still_works() {
  local port="$1"
  local path="$2"
  local body="$TMP_DIR/body-http-${port}-${path//\//_}"
  local status

  status="$(curl -ksS -H "Host: $SITE_DOMAIN" -o "$body" -w "%{http_code}" "https://127.0.0.1:$port$path")"
  if [[ "$status" != "200" ]] || ! grep -q "UPSTREAM_HTTP_CANARY" "$body"; then
    fail "expected normal HTTP proxying to work for port=$port path=$path status=$status"
    cat "$body" >&2
  fi
}

assert_untrusted_tls_upstream_blocked() {
  local port="$1"
  local path="$2"
  local body="$TMP_DIR/body-tls-${port}-${path//\//_}"
  local status

  status="$(curl -ksS -H "Host: $SITE_DOMAIN" -o "$body" -w "%{http_code}" "https://127.0.0.1:$port$path")"
  if [[ "$status" == "200" ]] || grep -q "UPSTREAM_TLS_CANARY" "$body"; then
    fail "nginx accepted an untrusted upstream TLS certificate for port=$port path=$path status=$status"
    cat "$body" >&2
  fi
}

assert_untrusted_tls_upstream_allowed_when_verify_off() {
  local port="$1"
  local path="$2"
  local body="$TMP_DIR/body-tls-off-${port}-${path//\//_}"
  local status

  status="$(curl -ksS -H "Host: $SITE_DOMAIN" -o "$body" -w "%{http_code}" "https://127.0.0.1:$port$path")"
  if [[ "$status" != "200" ]] || ! grep -q "UPSTREAM_TLS_CANARY" "$body"; then
    fail "expected HTTPS proxying with verification off to work for port=$port path=$path status=$status"
    cat "$body" >&2
  fi
}

assert_https_proxy_still_works() {
  local port="$1"
  local path="$2"
  local body="$TMP_DIR/body-https-${port}-${path//\//_}"
  local status

  status="$(curl -ksS -H "Host: $SITE_DOMAIN" -o "$body" -w "%{http_code}" "https://127.0.0.1:$port$path")"
  if [[ "$status" != "200" ]] || ! grep -q "UPSTREAM_TLS_CANARY" "$body"; then
    fail "expected trusted HTTPS proxying to work for port=$port path=$path status=$status"
    cat "$body" >&2
  fi
}

assert_deployment_image_pinned
assert_tls_name_defaults_to_backend_host
assert_static_tls_config
assert_panel_access_gate_config
assert_forwarded_for_sanitized

start_http_upstream
if wait_for_upstream http && start_nginx http; then
  assert_attacker_host_not_reflected "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/redirect"
  assert_attacker_host_not_reflected "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/redirect"
  assert_canonical_redirect "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/redirect"
  assert_canonical_redirect "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/redirect"
  assert_http_proxy_still_works "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health"
  assert_http_proxy_still_works "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/health"
fi
stop_nginx
stop_upstream

start_tls_upstream
if wait_for_upstream https && start_nginx https; then
  assert_untrusted_tls_upstream_blocked "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health"
  assert_untrusted_tls_upstream_blocked "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/health"
fi
stop_nginx
stop_upstream

start_tls_upstream
if wait_for_upstream https && start_nginx https 127.0.0.1 "" off; then
  assert_untrusted_tls_upstream_allowed_when_verify_off "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health"
  assert_untrusted_tls_upstream_allowed_when_verify_off "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/health"
fi
stop_nginx
stop_upstream

start_trusted_tls_upstream
if wait_for_upstream https && start_nginx https "$SITE_DOMAIN" "$TMP_DIR/upstream-ca.pem"; then
  assert_https_proxy_still_works "$PANEL_HTTPS_PORT" "$PANEL_PATH_PREFIX/health"
  assert_https_proxy_still_works "$SUBS_HTTPS_PORT" "$SUBS_PATH_PREFIX/health"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  echo "$FAILURES regression failure(s)" >&2
  exit 1
fi

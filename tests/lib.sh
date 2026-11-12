#!/usr/bin/env bash
# Shared harness for tests/*.sh: certificate, mock upstream, nginx container helpers, cleanup.
# Source it; it starts the mock upstream immediately and cleans up on EXIT.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.tmp"
export TMPDIR="$ROOT_DIR/.tmp" TEMP="$ROOT_DIR/.tmp" TMP="$ROOT_DIR/.tmp"
TMP_DIR="$(mktemp -d)"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30.6-alpine@sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311}"
SITE_DOMAIN="${SITE_DOMAIN:-example.test}"
PANEL_ALLOWED_CIDR="${PANEL_ALLOWED_CIDR:-127.0.0.1/32}"
PANEL_PATH_PREFIX="${PANEL_PATH_PREFIX:-/panel}"
SUBS_PATH_PREFIX="${SUBS_PATH_PREFIX:-/subs}"
SUBS_JSON_PATH_PREFIX="${SUBS_JSON_PATH_PREFIX:-}"
PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-$((28000 + RANDOM % 1000))}"
SUBS_HTTPS_PORT="${SUBS_HTTPS_PORT:-$((29000 + RANDOM % 1000))}"
UPSTREAM_PORT="${TEST_UPSTREAM_PORT:-$((30000 + RANDOM % 1000))}"
NGINX_CONTAINERS=()

stop_nginx() {
  local name
  for name in "${NGINX_CONTAINERS[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  NGINX_CONTAINERS=()
}

cleanup() {
  stop_nginx
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
        self.send_header("X-Seen-Forwarded-Prefix", self.headers.get("X-Forwarded-Prefix", ""))
        if self.path.endswith("/bigheader"):
            self.send_header("Per-App-Proxy-List", "a" * 6000)
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

NGINX_ARGS=(
  -e "MOSQUITO_SWATTER_EVENTS=0"
  -e "SITE_DOMAIN=$SITE_DOMAIN"
  -e "PANEL_HTTPS_PORT=$PANEL_HTTPS_PORT"
  -e "SUBS_HTTPS_PORT=$SUBS_HTTPS_PORT"
  -e "PANEL_ALLOWED_CIDR=$PANEL_ALLOWED_CIDR"
  -e "PANEL_PATH_PREFIX=$PANEL_PATH_PREFIX"
  -e "SUBS_PATH_PREFIX=$SUBS_PATH_PREFIX"
  -e "SUBS_JSON_PATH_PREFIX=$SUBS_JSON_PATH_PREFIX"
  -e "PANEL_BACKEND_SCHEME=http"
  -e "PANEL_BACKEND_HOST=127.0.0.1"
  -e "PANEL_BACKEND_PORT=$UPSTREAM_PORT"
  -e "PANEL_BACKEND_TLS_NAME=127.0.0.1"
  -e "PANEL_BACKEND_SSL_VERIFY=off"
  -e "SUBS_BACKEND_SCHEME=http"
  -e "SUBS_BACKEND_HOST=127.0.0.1"
  -e "SUBS_BACKEND_PORT=$UPSTREAM_PORT"
  -e "SUBS_BACKEND_TLS_NAME=127.0.0.1"
  -e "SUBS_BACKEND_SSL_VERIFY=off"
  -v "$ROOT_DIR/render.sh:/etc/nginx/render.sh:ro"
  -v "$ROOT_DIR/swatter.js:/etc/nginx/swatter.js:ro"
  -v "$ROOT_DIR/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro"
  -v "$ROOT_DIR/subs-proxy.conf:/etc/nginx/templates/subs-proxy.conf.template:ro"
  -v "$ROOT_DIR/html:/usr/share/nginx/html:ro"
  -v "$TMP_DIR/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro"
  -v "$TMP_DIR/privkey.pem:/etc/nginx/certs/privkey.pem:ro"
)
NGINX_COMMAND=(/bin/sh /etc/nginx/render.sh)

# start_nginx <name> [docker run args...]: extra args (e.g. -e overrides) follow the shared -e/-v.
# Containers share the host ports, so any previous one is removed first.
start_nginx() {
  local name="$1"
  shift
  stop_nginx
  NGINX_CONTAINERS+=("$name")
  NGINX_CONTAINER_ID="$(docker run -d --rm --name "$name" --network host \
    "${NGINX_ARGS[@]}" "$@" "$NGINX_IMAGE" "${NGINX_COMMAND[@]}")" || return 1

  for _ in {1..80}; do
    if curl -ksS -H "Host: $SITE_DOMAIN" "https://127.0.0.1:$PANEL_HTTPS_PORT/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "nginx test container did not become ready" >&2
  docker logs "$NGINX_CONTAINER_ID" >&2 || true
  return 1
}

# render_only [docker run args...]: render and `nginx -t` only; the exit code and stderr are the result.
render_only() {
  local name="3xui-fallback-render-$$-$RANDOM"
  NGINX_CONTAINERS+=("$name")
  # timeout: a render that forgets RENDER_ONLY would otherwise run nginx forever.
  timeout 30 docker run --rm --name "$name" --network none \
    "${NGINX_ARGS[@]}" -e RENDER_ONLY=1 "$@" "$NGINX_IMAGE" "${NGINX_COMMAND[@]}"
}

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

#!/bin/sh
# Renders /etc/nginx/nginx.conf from the template and starts nginx.
# Shared by docker-compose.yml and tests/lib.sh. RENDER_ONLY=1 stops after `nginx -t`.
set -e

# envsubst only these, so nginx runtime variables such as $host survive.
RENDER_VARS='$SITE_DOMAIN
$MOSQUITO_SWATTER_EVENTS
$PANEL_HTTPS_PORT $SUBS_HTTPS_PORT
$PANEL_ALLOWED_CIDR
$PANEL_PATH_PREFIX $SUBS_PATH_PREFIX
$PANEL_BACKEND_SCHEME
$PANEL_BACKEND_HOST $PANEL_BACKEND_PORT $PANEL_BACKEND_TLS_NAME $PANEL_BACKEND_SSL_VERIFY
$SUBS_BACKEND_SCHEME
$SUBS_BACKEND_HOST $SUBS_BACKEND_PORT $SUBS_BACKEND_TLS_NAME $SUBS_BACKEND_SSL_VERIFY'

umask 027

# PANEL_ALLOWED_CIDR is a space-separated list; each token becomes one allow line.
# Validate every token so a value like "1.2.3.4; allow all" cannot inject directives.
set -f
panel_allow=
for token in $PANEL_ALLOWED_CIDR; do
  if [ "$token" != all ] && ! printf '%s\n' "$token" | grep -Eqx '[0-9A-Fa-f:.]+(/[0-9]{1,3})?'; then
    echo "render.sh: bad PANEL_ALLOWED_CIDR token: $token" >&2
    exit 1
  fi
  panel_allow="${panel_allow}allow $token;
"
done
set +f
if [ -z "$panel_allow" ]; then
  echo "render.sh: bad PANEL_ALLOWED_CIDR token: " >&2
  exit 1
fi
printf '%s' "$panel_allow" > /etc/nginx/panel-allow.conf

mkdir -p /var/log/swatter
if [ "${MOSQUITO_SWATTER_EVENTS:-0}" = 1 ]; then
  ln -sf /dev/null /var/log/nginx/panel_error.log
  ln -sf /dev/null /var/log/nginx/subs_error.log
else
  ln -sf /dev/stdout /var/log/nginx/panel_access.log
  ln -sf /dev/stdout /var/log/nginx/subs_access.log
  ln -sf /dev/stderr /var/log/nginx/panel_error.log
  ln -sf /dev/stderr /var/log/nginx/subs_error.log
fi

export PANEL_BACKEND_TLS_NAME="${PANEL_BACKEND_TLS_NAME:-$PANEL_BACKEND_HOST}"
export SUBS_BACKEND_TLS_NAME="${SUBS_BACKEND_TLS_NAME:-$SUBS_BACKEND_HOST}"
if [ "${MOSQUITO_SWATTER_EVENTS:-0}" = 1 ]; then
  export MOSQUITO_SWATTER_EVENTS=1
else
  export MOSQUITO_SWATTER_EVENTS=0
fi

envsubst "$RENDER_VARS" < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
[ "${RENDER_ONLY:-0}" = 1 ] && exit 0
exec nginx -g 'daemon off;'

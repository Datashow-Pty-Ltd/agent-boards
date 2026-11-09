#!/bin/sh
set -eu

DNS_RESOLVER=$(awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf)
if [ -z "$DNS_RESOLVER" ]; then
  echo "No DNS resolver found in /etc/resolv.conf" >&2
  exit 1
fi

WEB_HOST=${WEB_HOST:-web}
REST_HOST=${REST_HOST:-postgrest}
MCP_HOST=${MCP_HOST:-mcp}
INTELLIGENCE_HOST=${INTELLIGENCE_HOST:-intelligence}

sed \
  -e "s/__DNS_RESOLVER__/$DNS_RESOLVER/g" \
  -e "s/__WEB_HOST__/$WEB_HOST/g" \
  -e "s/__REST_HOST__/$REST_HOST/g" \
  -e "s/__MCP_HOST__/$MCP_HOST/g" \
  -e "s/__INTELLIGENCE_HOST__/$INTELLIGENCE_HOST/g" \
  /usr/local/openresty/nginx/conf/nginx.conf.template \
  > /usr/local/openresty/nginx/conf/nginx.conf

exec /usr/local/openresty/bin/openresty -g 'daemon off;'

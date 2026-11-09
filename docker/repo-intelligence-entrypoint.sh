#!/bin/sh
set -eu

mkdir -p "${REPOSITORY_ROOT:-/data/repositories}"
chown -R node:node "${REPOSITORY_ROOT:-/data/repositories}"
exec su-exec node node dist/server.js

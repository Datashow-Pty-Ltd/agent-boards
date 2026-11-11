#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ACTION=${1:-up}

# Same settings file as Docker Compose: read KEY=VALUE lines from .env without
# executing it. As with Compose, variables already set in the caller's
# environment win over the file.
if [ -f "$ROOT_DIR/.env" ]; then
  cr=$(printf '\r')
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$cr"}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    [ "$key" = "$line" ] && continue
    key=$(printf '%s' "$key" | sed 's/^export[[:space:]][[:space:]]*//; s/[[:space:]]*$//')
    case "$key" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
    esac
    eval "already=\${${key}+set}"
    [ -n "$already" ] && continue
    value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
      *) value=$(printf '%s' "$value" | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//') ;;
    esac
    export "$key=$value"
  done < "$ROOT_DIR/.env"
fi
NETWORK=agent-boards-net
VOLUME=agent-boards-postgres
UPLOAD_VOLUME=agent-boards-uploads
REPOSITORY_VOLUME=agent-boards-repositories
DB=agent-boards-db
REST=agent-boards-rest
INTELLIGENCE=agent-boards-repo-intelligence
MCP=agent-boards-mcp
WEB=agent-boards-web
GATEWAY=agent-boards-gateway
HOST_PORT=${AGENT_BOARDS_PORT:-4747}
BIND_ADDRESS=${AGENT_BOARDS_BIND:-127.0.0.1}
STACK_LABEL=com.datashow.application.stack=agent-boards
DNS_DOMAIN=${AGENT_BOARDS_DNS_DOMAIN:-$(container system property list | awk '
  /^\[dns\]$/ { in_dns = 1; next }
  /^\[/ { in_dns = 0 }
  in_dns && /^domain = / { gsub(/^domain = "|"$/, ""); print; exit }
')}

if [ -z "$DNS_DOMAIN" ]; then
  echo "Apple Container has no DNS domain configured." >&2
  exit 1
fi

# Fails when another process already listens on the gateway port. A process
# bound to 127.0.0.1 would otherwise silently shadow the gateway for local
# clients such as MCP, which then see that process's 404s.
# Retries briefly, because a just-deleted gateway's runtime helper can take a
# moment to close its socket. lsof only sees this user's processes; a socket
# owned by another user still makes the publish itself fail.
check_port_free() {
  command -v lsof >/dev/null 2>&1 || return 0
  tries=0
  while :; do
    listeners=$(lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ") " $9 }' | sort -u)
    [ -z "$listeners" ] && return 0
    tries=$((tries + 1))
    [ "$tries" -ge 10 ] && break
    sleep 1
  done
  if [ -n "$listeners" ]; then
    echo "Port ${HOST_PORT} is already in use:" >&2
    echo "$listeners" >&2
    echo "Stop that process or set AGENT_BOARDS_PORT to a free port." >&2
    exit 1
  fi
}

# Private repository indexing needs a GitHub token. Fall back to the GitHub
# CLI's credential when GITHUB_TOKEN is not set; the value is never printed.
# The gh credential is usually broad (repo, workflow, read:org); set
# AGENT_BOARDS_USE_GH_TOKEN=0 to disable the fallback, or export a narrow
# read-only GITHUB_TOKEN instead.
resolve_github_token() {
  if [ -z "${GITHUB_TOKEN:-}" ] && [ "${AGENT_BOARDS_USE_GH_TOKEN:-1}" != "0" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
    if [ -n "$GITHUB_TOKEN" ]; then
      echo "Using the GitHub CLI credential for private repository indexing (AGENT_BOARDS_USE_GH_TOKEN=0 disables this)."
    fi
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GITHUB_TOKEN
  else
    unset GITHUB_TOKEN
    echo "No GITHUB_TOKEN or GitHub CLI login found; only public repositories can be indexed."
  fi
}

delete_containers() {
  for name in "$GATEWAY" "$WEB" "$MCP" "$INTELLIGENCE" "$REST" "$DB"; do
    container delete --force "$name" >/dev/null 2>&1 || true
  done
}

build_images() {
  container system start >/dev/null 2>&1 || true
  echo "Building Agent Boards images with Apple Container..."
  container build --progress plain -t agent-boards-postgres:dev -f "$ROOT_DIR/docker/postgres.Containerfile" "$ROOT_DIR"
  container build --progress plain -t agent-boards-mcp:dev -f "$ROOT_DIR/docker/mcp.Containerfile" "$ROOT_DIR"
  container build --progress plain -t agent-boards-repo-intelligence:dev -f "$ROOT_DIR/docker/repo-intelligence.Containerfile" "$ROOT_DIR"
  container build --progress plain -t agent-boards-web:dev -f "$ROOT_DIR/docker/web.Containerfile" "$ROOT_DIR"
  container build --progress plain -t agent-boards-gateway:dev -f "$ROOT_DIR/docker/gateway.Containerfile" "$ROOT_DIR"
}

case "$ACTION" in
  build)
    build_images
    ;;
  up)
    container system start >/dev/null 2>&1 || true
    container network create "$NETWORK" >/dev/null 2>&1 || true
    container volume create -s 4G "$VOLUME" >/dev/null 2>&1 || true
    container volume create -s 4G "$UPLOAD_VOLUME" >/dev/null 2>&1 || true
    container volume create -s 8G "$REPOSITORY_VOLUME" >/dev/null 2>&1 || true
    delete_containers
    check_port_free
    resolve_github_token

    build_images

    echo "Starting PostgreSQL..."
    container run -d --name "$DB" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK,alias=db" \
      --volume "$VOLUME:/var/lib/postgresql/data" \
      --env PGDATA=/var/lib/postgresql/data/pgdata \
      --env POSTGRES_DB=agentboards --env POSTGRES_USER=agentboards --env POSTGRES_PASSWORD=agentboards \
      agent-boards-postgres:dev >/dev/null

    attempts=0
    until container exec "$DB" pg_isready -U agentboards -d agentboards >/dev/null 2>&1; do
      attempts=$((attempts + 1))
      if [ "$attempts" -gt 60 ]; then
        echo "PostgreSQL did not become ready." >&2
        container logs "$DB"
        exit 1
      fi
      sleep 1
    done

    container exec "$DB" psql -v ON_ERROR_STOP=1 -U agentboards -d agentboards -c \
      "CREATE TABLE IF NOT EXISTS public.schema_migrations (filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())" >/dev/null
    baseline=$(container exec "$DB" psql -At -U agentboards -d agentboards -c \
      "SELECT to_regprocedure('api.complete_task(uuid,text,text)') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.schema_migrations)")
    if [ "$baseline" = "t" ]; then
      for migration in "$ROOT_DIR"/database/migrations/*.sql; do
        migration_name=$(basename "$migration")
        case "$migration_name" in
          00[2-9]-*|0[12][0-9]-*|03[0-3]-*)
            container exec "$DB" psql -v ON_ERROR_STOP=1 -U agentboards -d agentboards -c \
              "INSERT INTO public.schema_migrations(filename) VALUES ('$migration_name') ON CONFLICT DO NOTHING" >/dev/null
            ;;
        esac
      done
    fi
    for migration in "$ROOT_DIR"/database/migrations/*.sql; do
      migration_name=$(basename "$migration")
      applied=$(container exec "$DB" psql -At -U agentboards -d agentboards -c \
        "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE filename = '$migration_name')")
      if [ "$applied" = "f" ]; then
        container exec --interactive "$DB" psql -v ON_ERROR_STOP=1 -U agentboards -d agentboards < "$migration" >/dev/null
        container exec "$DB" psql -v ON_ERROR_STOP=1 -U agentboards -d agentboards -c \
          "INSERT INTO public.schema_migrations(filename) VALUES ('$migration_name')" >/dev/null
      fi
    done

    echo "Starting PostgREST, repository intelligence, MCP, web, and OpenResty gateway..."
    container run -d --name "$REST" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK,alias=postgrest" \
      --env PGRST_DB_URI="postgres://authenticator:postgrest@db.${DNS_DOMAIN}:5432/agentboards" \
      --env PGRST_DB_SCHEMAS=api --env PGRST_DB_ANON_ROLE=web_anon --env PGRST_SERVER_PORT=3000 \
      postgrest/postgrest:v16.5 >/dev/null
    container run -d --name "$INTELLIGENCE" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK,alias=intelligence" \
      --volume "$REPOSITORY_VOLUME:/data/repositories" \
      --env POSTGREST_URL="http://postgrest.${DNS_DOMAIN}:3000" --env PORT=8081 --env GITHUB_TOKEN \
      agent-boards-repo-intelligence:dev >/dev/null
    container run -d --name "$MCP" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK,alias=mcp" \
      --volume "$UPLOAD_VOLUME:/data/uploads" \
      --env POSTGREST_URL="http://postgrest.${DNS_DOMAIN}:3000" --env REPO_INTELLIGENCE_URL="http://intelligence.${DNS_DOMAIN}:8081" --env PORT=8080 \
      agent-boards-mcp:dev >/dev/null
    # A named volume is mounted after the image filesystem is prepared, so set
    # its ownership explicitly for the non-root MCP process on every startup.
    container exec --user root "$MCP" chown -R node:node /data/uploads
    container run -d --name "$WEB" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK,alias=web" \
      agent-boards-web:dev >/dev/null
    container run -d --name "$GATEWAY" --label "$STACK_LABEL" --dns-domain "$DNS_DOMAIN" --network "$NETWORK" \
      --publish "${BIND_ADDRESS}:${HOST_PORT}:8080" \
      --env WEB_HOST="web.${DNS_DOMAIN}" --env REST_HOST="postgrest.${DNS_DOMAIN}" \
      --env MCP_HOST="mcp.${DNS_DOMAIN}" --env INTELLIGENCE_HOST="intelligence.${DNS_DOMAIN}" \
      agent-boards-gateway:dev >/dev/null

    case "$BIND_ADDRESS" in
      0.0.0.0|::|'') URL_HOST=127.0.0.1 ;;
      *:*) URL_HOST="[$BIND_ADDRESS]" ;;
      *) URL_HOST=$BIND_ADDRESS ;;
    esac
    echo "Agent Boards is running at http://${URL_HOST}:${HOST_PORT}"
    echo "REST API: http://${URL_HOST}:${HOST_PORT}/api/"
    echo "MCP:      http://${URL_HOST}:${HOST_PORT}/mcp"
    echo "Intel:    http://${URL_HOST}:${HOST_PORT}/intelligence/"
    ;;
  down)
    delete_containers
    echo "Agent Boards containers stopped. Data remains in volume ${VOLUME}."
    ;;
  status)
    container list --all
    ;;
  logs)
    for name in "$DB" "$REST" "$INTELLIGENCE" "$MCP" "$WEB" "$GATEWAY"; do
      echo "[$name]"
      container logs "$name" 2>&1 | tail -n 80 || true
    done
    ;;
  *)
    echo "Usage: $0 {build|up|down|status|logs}" >&2
    exit 2
    ;;
esac

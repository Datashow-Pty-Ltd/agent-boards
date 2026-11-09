#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ACTION=${1:-up}
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
HOST_PORT=${AGENT_BOARDS_PORT:-4173}
STACK_LABEL=com.datashow.application.stack=agent-boards

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

    build_images

    echo "Starting PostgreSQL..."
    container run -d --name "$DB" --label "$STACK_LABEL" --network "$NETWORK,alias=db" \
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

    for migration in "$ROOT_DIR"/database/migrations/*.sql; do
      container exec --interactive "$DB" psql -v ON_ERROR_STOP=1 -U agentboards -d agentboards < "$migration" >/dev/null
    done

    echo "Starting PostgREST, repository intelligence, MCP, web, and OpenResty gateway..."
    container run -d --name "$REST" --label "$STACK_LABEL" --network "$NETWORK,alias=postgrest" \
      --env PGRST_DB_URI=postgres://authenticator:postgrest@db:5432/agentboards \
      --env PGRST_DB_SCHEMAS=api --env PGRST_DB_ANON_ROLE=web_anon --env PGRST_SERVER_PORT=3000 \
      postgrest/postgrest:v16.5 >/dev/null
    container run -d --name "$INTELLIGENCE" --label "$STACK_LABEL" --network "$NETWORK,alias=intelligence" \
      --volume "$REPOSITORY_VOLUME:/data/repositories" \
      --env POSTGREST_URL=http://postgrest:3000 --env PORT=8081 --env GITHUB_TOKEN \
      agent-boards-repo-intelligence:dev >/dev/null
    container run -d --name "$MCP" --label "$STACK_LABEL" --network "$NETWORK,alias=mcp" \
      --volume "$UPLOAD_VOLUME:/data/uploads" \
      --env POSTGREST_URL=http://postgrest:3000 --env REPO_INTELLIGENCE_URL=http://intelligence:8081 --env PORT=8080 \
      agent-boards-mcp:dev >/dev/null
    # A named volume is mounted after the image filesystem is prepared, so set
    # its ownership explicitly for the non-root MCP process on every startup.
    container exec --user root "$MCP" chown -R node:node /data/uploads
    container run -d --name "$WEB" --label "$STACK_LABEL" --network "$NETWORK,alias=web" \
      agent-boards-web:dev >/dev/null
    container run -d --name "$GATEWAY" --label "$STACK_LABEL" --network "$NETWORK" \
      --publish "${HOST_PORT}:8080" \
      --env WEB_HOST=web.rivyr --env REST_HOST=postgrest.rivyr \
      --env MCP_HOST=mcp.rivyr --env INTELLIGENCE_HOST=intelligence.rivyr \
      agent-boards-gateway:dev >/dev/null

    echo "Agent Boards is running at http://localhost:${HOST_PORT}"
    echo "REST API: http://localhost:${HOST_PORT}/api/"
    echo "MCP:      http://localhost:${HOST_PORT}/mcp"
    echo "Intel:    http://localhost:${HOST_PORT}/intelligence/"
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

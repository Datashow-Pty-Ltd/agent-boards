# tree-sitter 0.21's native binding is not compatible with Node 24's ABI/C++20
# requirements. Keep this service on the current Node 22 LTS until the parser
# packages are upgraded together.
FROM node:22-alpine AS build
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY apps/repo-intelligence/package.json ./package.json
COPY pnpm-workspace.yaml ./pnpm-workspace.yaml
RUN corepack enable && corepack prepare pnpm@10.26.1 --activate && pnpm install --frozen-lockfile=false
COPY apps/repo-intelligence/tsconfig.json ./tsconfig.json
COPY apps/repo-intelligence/src ./src
RUN pnpm build && pnpm prune --prod

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=8081 REPOSITORY_ROOT=/data/repositories
RUN apk add --no-cache ca-certificates git ripgrep su-exec
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY docker/repo-intelligence-entrypoint.sh /usr/local/bin/agent-boards-repo-intelligence
RUN chmod +x /usr/local/bin/agent-boards-repo-intelligence \
  && mkdir -p /data/repositories \
  && chown -R node:node /data/repositories
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/agent-boards-repo-intelligence"]

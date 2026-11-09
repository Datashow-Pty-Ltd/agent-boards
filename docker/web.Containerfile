FROM node:24-alpine AS build
WORKDIR /workspace
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/web/package.json ./apps/web/package.json
RUN corepack enable && corepack prepare pnpm@10.26.1 --activate \
  && pnpm install --filter @agent-boards/web... --frozen-lockfile
COPY apps/web ./apps/web
RUN pnpm --filter @agent-boards/web build

FROM node:24-alpine
WORKDIR /app
ENV PORT=5173
RUN corepack disable && rm -rf /usr/local/lib/node_modules/npm
COPY LICENSE NOTICE /usr/local/share/licenses/agent-boards/
COPY --from=build --chown=node:node /workspace/apps/web/dist ./dist
COPY --chown=node:node docker/web-server.mjs ./server.mjs
USER node
EXPOSE 5173
CMD ["node", "server.mjs"]

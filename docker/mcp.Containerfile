FROM node:24-alpine AS build
WORKDIR /app
COPY apps/mcp/package.json ./package.json
COPY pnpm-workspace.yaml ./pnpm-workspace.yaml
RUN corepack enable && corepack prepare pnpm@10.26.1 --activate && pnpm install --frozen-lockfile=false
COPY apps/mcp/tsconfig.json ./tsconfig.json
COPY apps/mcp/src ./src
COPY apps/mcp/skills ./skills
RUN pnpm build && pnpm prune --prod

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=8080
RUN apk add --no-cache ffmpeg \
  && corepack disable \
  && rm -rf /usr/local/lib/node_modules/npm
COPY LICENSE NOTICE /usr/local/share/licenses/agent-boards/
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/skills ./skills
RUN mkdir -p /data/uploads && chown -R node:node /data/uploads
USER node
EXPOSE 8080
CMD ["node", "dist/server.js"]

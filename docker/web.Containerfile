FROM node:24-alpine
WORKDIR /app
COPY apps/web/package.json ./package.json
COPY pnpm-workspace.yaml ./pnpm-workspace.yaml
RUN corepack enable && corepack prepare pnpm@10.26.1 --activate \
  && pnpm install --frozen-lockfile=false
COPY apps/web ./
EXPOSE 5173
CMD ["pnpm", "dev"]

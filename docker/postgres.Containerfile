FROM postgres:17-alpine
# Pick up Alpine security fixes published after the upstream image was built.
RUN apk upgrade --no-cache
COPY LICENSE NOTICE /usr/local/share/licenses/agent-boards/
COPY database/init.sql /docker-entrypoint-initdb.d/001-agent-boards.sql

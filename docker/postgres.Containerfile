FROM postgres:17-alpine
COPY LICENSE NOTICE /usr/local/share/licenses/agent-boards/
COPY database/init.sql /docker-entrypoint-initdb.d/001-agent-boards.sql

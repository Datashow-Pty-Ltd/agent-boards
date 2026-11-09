FROM postgres:17-alpine
COPY database/init.sql /docker-entrypoint-initdb.d/001-agent-boards.sql

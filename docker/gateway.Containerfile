FROM openresty/openresty:1.29.2.4-alpine-fat

COPY LICENSE NOTICE /usr/local/share/licenses/agent-boards/
COPY docker/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.template
COPY docker/gateway-entrypoint.sh /usr/local/bin/agent-boards-gateway
RUN apk upgrade --no-cache \
  && chmod +x /usr/local/bin/agent-boards-gateway \
  && chown -R nobody:nobody /usr/local/openresty/nginx

USER nobody
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/agent-boards-gateway"]

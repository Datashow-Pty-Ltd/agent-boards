FROM openresty/openresty:1.29.2.4-alpine-fat

COPY docker/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.template
COPY docker/gateway-entrypoint.sh /usr/local/bin/agent-boards-gateway
RUN chmod +x /usr/local/bin/agent-boards-gateway

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/agent-boards-gateway"]

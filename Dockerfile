FROM redis:7.4-alpine

COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod 755 /usr/local/bin/node-entrypoint.sh \
    && mkdir -p /etc/redis

WORKDIR /data
EXPOSE 6379 26379
ENTRYPOINT ["node-entrypoint.sh"]

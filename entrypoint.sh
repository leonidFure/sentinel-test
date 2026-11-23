#!/bin/sh
# Redis и Sentinel в одном контейнере. Клиенты в sentinel-net ходят по именам node1/node2/node3.
set -eu

MASTER_NAME="${MASTER_NAME:-mymaster}"
QUORUM="${QUORUM:-2}"
DOWN_AFTER_MS="${DOWN_AFTER_MS:-3000}"
FAILOVER_TIMEOUT="${FAILOVER_TIMEOUT:-15000}"
ROLE="${ROLE:?ROLE is required (master, slave, or sentinel)}"

if [ "$(id -u)" = "0" ]; then
  chown -R redis:redis /data
  exec /bin/setpriv --reuid redis --regid redis --clear-groups /usr/local/bin/node-entrypoint.sh
fi

umask 0077

write_sentinel_conf() {
  cat > /data/sentinel.conf <<EOF
bind 0.0.0.0
protected-mode no
port 26379
dir /data
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor ${MASTER_NAME} node1 6379 ${QUORUM}
sentinel down-after-milliseconds ${MASTER_NAME} ${DOWN_AFTER_MS}
sentinel failover-timeout ${MASTER_NAME} ${FAILOVER_TIMEOUT}
sentinel parallel-syncs ${MASTER_NAME} 1
EOF
  chmod 600 /data/sentinel.conf
}

REDIS_PID=""
SENTINEL_PID=""

shutdown() {
  if [ -n "$REDIS_PID" ]; then
    kill "$REDIS_PID" 2>/dev/null || true
  fi
  if [ -n "$SENTINEL_PID" ]; then
    kill "$SENTINEL_PID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

case "$ROLE" in
  master|slave)
    NODE_NAME="${NODE_NAME:?NODE_NAME is required}"
    {
      echo "bind 0.0.0.0"
      echo "protected-mode no"
      echo "port 6379"
      echo "dir /data"
      echo "appendonly yes"
      echo "replica-announce-ip ${NODE_NAME}"
      echo "replica-announce-port 6379"
      if [ "$ROLE" != "master" ]; then
        echo "replicaof node1 6379"
      fi
    } > /data/redis.conf
    chmod 600 /data/redis.conf
    write_sentinel_conf

    redis-server /data/redis.conf &
    REDIS_PID=$!

    ready=0
    i=0
    while [ "$i" -lt 50 ]; do
      if redis-cli -t 2 -p 6379 PING 2>/dev/null | grep -q PONG; then
        ready=1
        break
      fi
      if ! kill -0 "$REDIS_PID" 2>/dev/null; then
        echo "redis-server exited during startup" >&2
        exit 1
      fi
      i=$((i + 1))
      sleep 0.2
    done
    if [ "$ready" -ne 1 ]; then
      echo "redis-server did not become ready" >&2
      exit 1
    fi

    redis-sentinel /data/sentinel.conf &
    SENTINEL_PID=$!
    ;;
  sentinel)
    write_sentinel_conf
    redis-sentinel /data/sentinel.conf &
    SENTINEL_PID=$!
    ;;
  *)
    echo "invalid ROLE: ${ROLE}" >&2
    exit 1
    ;;
esac

while true; do
  if [ -n "$REDIS_PID" ] && ! kill -0 "$REDIS_PID" 2>/dev/null; then
    echo "redis-server exited" >&2
    kill "$SENTINEL_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "redis-sentinel exited" >&2
    if [ -n "$REDIS_PID" ]; then
      kill "$REDIS_PID" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

#!/bin/sh
# Копирует смонтированные конфиги в /data: Sentinel переписывает свой файл во время работы.
set -eu

if [ "$(id -u)" = "0" ]; then
  chown -R redis:redis /data
  exec /bin/setpriv --reuid redis --regid redis --clear-groups /usr/local/bin/node-entrypoint.sh
fi

umask 0077

if [ ! -f /etc/redis/sentinel.conf ]; then
  echo "missing /etc/redis/sentinel.conf" >&2
  exit 1
fi

cp /etc/redis/sentinel.conf /data/sentinel.conf
chmod 600 /data/sentinel.conf

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

if [ -f /etc/redis/redis.conf ]; then
  cp /etc/redis/redis.conf /data/redis.conf
  chmod 600 /data/redis.conf

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
fi

redis-sentinel /data/sentinel.conf &
SENTINEL_PID=$!

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

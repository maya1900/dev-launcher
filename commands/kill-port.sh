#!/usr/bin/env bash
# desc: 释放指定 TCP 端口
# usage: dev c x kill-port <port>

set -euo pipefail

port="${1:-}"

if [ -z "$port" ]; then
  echo "用法: dev c x kill-port <port>" >&2
  exit 1
fi

if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  echo "端口必须是 1-65535 之间的数字: $port" >&2
  exit 1
fi

if ! command -v lsof >/dev/null 2>&1; then
  echo "找不到 lsof 命令" >&2
  exit 1
fi

pids="$(lsof -ti tcp:"$port" || true)"

if [ -z "$pids" ]; then
  echo "端口 $port 没有进程占用"
  exit 0
fi

echo "将释放端口 ${port}，PID:"
printf '%s\n' "$pids"

pid_still_owns_port() {
  local pid="$1"
  lsof -ti tcp:"$port" -a -p "$pid" 2>/dev/null | grep -qx "$pid"
}

signal_pids() {
  local signal="$1"
  local pid_list="$2"
  local pid

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if ! pid_still_owns_port "$pid"; then
      echo "跳过 PID，已不再占用端口 $port: $pid"
      continue
    fi

    if ! kill "$signal" "$pid" 2>/dev/null; then
      echo "发送 $signal 失败，PID 可能已经退出: $pid" >&2
    fi
  done <<< "$pid_list"
}

signal_pids -TERM "$pids"

sleep 1
pids="$(lsof -ti tcp:"$port" || true)"

if [ -n "$pids" ]; then
  echo "端口 $port 仍被占用，尝试 SIGKILL:"
  printf '%s\n' "$pids"

  signal_pids -KILL "$pids"

  sleep 1
  pids="$(lsof -ti tcp:"$port" || true)"
  if [ -n "$pids" ]; then
    echo "端口 $port 仍未释放，剩余 PID:" >&2
    printf '%s\n' "$pids" >&2
    exit 1
  fi
fi

echo "已释放端口 $port"

#!/usr/bin/env bash
set -euo pipefail

export OLLAYA_HOST="${OLLAYA_HOST:-0.0.0.0:11435}"
export OLLAYA_KEEP_ALIVE="${OLLAYA_KEEP_ALIVE:--1}"

ollaya serve &
server_pid=$!

cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  if ollaya list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! ollaya list >/dev/null 2>&1; then
  echo "Ollaya did not become ready within 60 seconds." >&2
  exit 1
fi

ollaya pull "${OLLAYA_BASE_MODEL:-laya:en}"
ollaya create "${OLLAYA_ROUTER_MODEL:-coding-router}" -f /home/ollaya/Modelfile

wait "$server_pid"

#!/usr/bin/env bash
set -euo pipefail

export OLLAYA_HOST="${OLLAYA_HOST:-0.0.0.0:11435}"
export OLLAYA_KEEP_ALIVE="${OLLAYA_KEEP_ALIVE:--1}"
base_model="${OLLAYA_BASE_MODEL:-winnow:e4b}"
model="${OLLAYA_MODEL:-massive-classifier}"

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

echo "Ensuring ${base_model} is present in the Ollaya model cache..."
ollaya pull "$base_model"
ollaya create "$model" -f /home/ollaya/Modelfile

echo "Warming ${model} before reporting readiness..."
ollaya run --format json --keepalive -1 "$model" \
  "set an alarm for seven tomorrow morning" >/tmp/ollaya-warmup.json
touch /tmp/ollaya-ready

wait "$server_pid"

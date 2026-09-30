#!/usr/bin/env sh
set -eu

get_value() {
  azd env get-value "$1" 2>/dev/null || true
}

if [ -z "$(get_value AZURE_LOCATION)" ]; then
  azd env set AZURE_LOCATION southcentralus >/dev/null
fi
if [ -z "$(get_value LUNA_CAPACITY)" ]; then
  azd env set LUNA_CAPACITY 10 >/dev/null
fi
if [ -z "$(get_value TERRA_CAPACITY)" ]; then
  azd env set TERRA_CAPACITY 10 >/dev/null
fi
if [ -z "$(get_value SOL_CAPACITY)" ]; then
  azd env set SOL_CAPACITY 10 >/dev/null
fi
if [ -z "$(get_value ROUTER_API_KEY)" ]; then
  key="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  azd env set ROUTER_API_KEY "$key" >/dev/null
fi

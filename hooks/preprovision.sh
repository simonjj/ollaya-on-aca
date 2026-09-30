#!/usr/bin/env bash
set -euo pipefail

get_value() {
  azd env get-value "$1" 2>/dev/null || true
}

set_default() {
  local name="$1"
  local value="$2"
  if [[ -z "$(get_value "$name")" ]]; then
    azd env set "$name" "$value" >/dev/null
  fi
}

set_default AZURE_LOCATION southcentralus
set_default DEPLOYMENT_MODE full
set_default NANO_CAPACITY 100
set_default GPU_MIN_REPLICAS 1
set_default MODEL_READY_TIMEOUT_MINUTES 120

deployment_mode="$(get_value DEPLOYMENT_MODE)"
if [[ "$deployment_mode" != "full" && "$deployment_mode" != "ollaya-only" ]]; then
  echo "DEPLOYMENT_MODE must be full or ollaya-only." >&2
  exit 1
fi

if [[ -z "$(get_value CLASSIFIER_API_KEY)" ]]; then
  classifier_api_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  azd env set CLASSIFIER_API_KEY "$classifier_api_key" >/dev/null
fi

gpu_profile="$(az containerapp env workload-profile list-supported \
  --location southcentralus \
  --query "[?name=='Consumption-GPU-NC8as-T4'].name | [0]" \
  -o tsv \
  --only-show-errors)"
if [[ "$gpu_profile" != "Consumption-GPU-NC8as-T4" ]]; then
  echo "Consumption-GPU-NC8as-T4 is not available in South Central US for this subscription." >&2
  exit 1
fi

if [[ "$deployment_mode" == "full" ]]; then
  nano_limit="$(az cognitiveservices usage list \
    --location eastus2 \
    --query "[?name.value=='OpenAI.GlobalStandard.gpt-5.4-nano'].limit | [0]" \
    -o tsv \
    --only-show-errors)"
  nano_capacity="$(get_value NANO_CAPACITY)"
  if [[ -z "$nano_limit" || "$nano_limit" == "0" ]]; then
    echo "GPT-5.4 Nano Global Standard quota is unavailable in East US 2." >&2
    exit 1
  fi
  if (( nano_capacity > ${nano_limit%.*} )); then
    echo "NANO_CAPACITY $nano_capacity exceeds the available quota limit $nano_limit." >&2
    exit 1
  fi
fi

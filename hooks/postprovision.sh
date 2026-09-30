#!/usr/bin/env bash
set -euo pipefail

get_value() {
  local value
  value="$(azd env get-value "$1" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    echo "Missing azd environment value: $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

container_app_exists() {
  az containerapp show --name "$1" --resource-group "$2" --only-show-errors >/dev/null 2>&1
}

deploy_container_app() {
  local name="$1"
  local resource_group="$2"
  local configuration_path="$3"
  if container_app_exists "$name" "$resource_group"; then
    az containerapp update \
      --name "$name" \
      --resource-group "$resource_group" \
      --yaml "$configuration_path" \
      --only-show-errors >/dev/null
  else
    az containerapp create \
      --name "$name" \
      --resource-group "$resource_group" \
      --yaml "$configuration_path" \
      --only-show-errors >/dev/null
  fi
}

wait_revision_healthy() {
  local name="$1"
  local resource_group="$2"
  local revision="$3"
  local timeout_minutes="$4"
  local deadline=$((SECONDS + timeout_minutes * 60))
  local state
  while (( SECONDS < deadline )); do
    state="$(az containerapp revision show \
      --name "$name" \
      --resource-group "$resource_group" \
      --revision "$revision" \
      --query "join('|', [properties.healthState, properties.runningState])" \
      -o tsv \
      --only-show-errors)"
    if [[ "$state" == "Healthy|RunningAtMaxScale" ]]; then
      return
    fi
    sleep 10
  done
  echo "Revision $revision did not become healthy within $timeout_minutes minutes." >&2
  exit 1
}

resource_group="$(get_value AZURE_RESOURCE_GROUP)"
location="$(get_value AZURE_LOCATION)"
deployment_mode="$(get_value DEPLOYMENT_MODE)"
environment_id="$(get_value AZURE_CONTAINER_APPS_ENVIRONMENT_ID)"
acr_name="$(get_value ACR_NAME)"
acr_login_server="$(get_value ACR_LOGIN_SERVER)"
identity_id="$(get_value APP_IDENTITY_ID)"
identity_client_id="$(get_value APP_IDENTITY_CLIENT_ID)"
ollaya_app_name="$(get_value OLLAYA_APP_NAME)"
api_app_name="$(get_value CLASSIFIER_API_APP_NAME)"
model_storage_name="$(get_value MODEL_STORAGE_NAME)"
gpu_workload_profile_name="$(get_value GPU_WORKLOAD_PROFILE_NAME)"
classifier_api_key="$(get_value CLASSIFIER_API_KEY)"
gpu_min_replicas="$(get_value GPU_MIN_REPLICAS)"
model_ready_timeout_minutes="$(get_value MODEL_READY_TIMEOUT_MINUTES)"
nano_endpoint=""
nano_deployment=""
if [[ "$deployment_mode" == "full" ]]; then
  nano_endpoint="$(get_value NANO_ENDPOINT)"
  nano_deployment="$(get_value NANO_DEPLOYMENT)"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_prefix="ollaya-on-aca"
image_tag="$(date -u +%Y%m%d%H%M%S)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

echo "Building immutable Ollaya and classifier API images..."
az acr build \
  --registry "$acr_name" \
  --image "$image_prefix/ollaya:$image_tag" \
  --file "$repo_root/app/ollaya/Dockerfile" \
  "$repo_root" \
  --only-show-errors
az acr build \
  --registry "$acr_name" \
  --image "$image_prefix/api:$image_tag" \
  --file "$repo_root/app/api/Dockerfile" \
  "$repo_root" \
  --only-show-errors

ollaya_image="$acr_login_server/$image_prefix/ollaya:$image_tag"
api_image="$acr_login_server/$image_prefix/api:$image_tag"
ollaya_config="$temp_root/ollaya.json"
api_config="$temp_root/api.json"

export location environment_id acr_login_server identity_id ollaya_image
export model_storage_name gpu_workload_profile_name gpu_min_replicas
python3 - "$ollaya_config" <<'PY'
import json
import os
import sys

identity_id = os.environ["identity_id"]
configuration = {
    "location": os.environ["location"],
    "identity": {
        "type": "UserAssigned",
        "userAssignedIdentities": {identity_id: {}},
    },
    "properties": {
        "environmentId": os.environ["environment_id"],
        "workloadProfileName": os.environ["gpu_workload_profile_name"],
        "configuration": {
            "activeRevisionsMode": "Single",
            "ingress": {
                "external": False,
                "targetPort": 11435,
                "transport": "Auto",
                "allowInsecure": False,
                "traffic": [{"latestRevision": True, "weight": 100}],
            },
            "registries": [
                {
                    "server": os.environ["acr_login_server"],
                    "identity": identity_id,
                }
            ],
        },
        "template": {
            "containers": [
                {
                    "name": "ollaya",
                    "image": os.environ["ollaya_image"],
                    "env": [
                        {"name": "OLLAYA_BASE_MODEL", "value": "winnow:e4b"},
                        {"name": "OLLAYA_MODEL", "value": "massive-classifier"},
                        {"name": "OLLAYA_KEEP_ALIVE", "value": "-1"},
                        {"name": "OLLAYA_DEVICE", "value": "cuda"},
                    ],
                    "resources": {"cpu": 8.0, "memory": "56Gi"},
                    "volumeMounts": [
                        {
                            "volumeName": "ollaya-models",
                            "mountPath": "/home/ollaya/.ollaya/models",
                        }
                    ],
                }
            ],
            "scale": {
                "minReplicas": int(os.environ["gpu_min_replicas"]),
                "maxReplicas": 1,
            },
            "volumes": [
                {
                    "name": "ollaya-models",
                    "storageType": "AzureFile",
                    "storageName": os.environ["model_storage_name"],
                }
            ],
        },
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(configuration, handle)
PY

deploy_container_app "$ollaya_app_name" "$resource_group" "$ollaya_config"
ollaya_fqdn="$(az containerapp show \
  --name "$ollaya_app_name" \
  --resource-group "$resource_group" \
  --query properties.configuration.ingress.fqdn \
  -o tsv \
  --only-show-errors)"
if [[ -z "$ollaya_fqdn" ]]; then
  echo "The Ollaya app has no internal FQDN." >&2
  exit 1
fi

enable_azure=false
if [[ "$deployment_mode" == "full" ]]; then
  enable_azure=true
fi
export api_image classifier_api_key ollaya_fqdn enable_azure
export identity_client_id nano_endpoint nano_deployment
python3 - "$api_config" <<'PY'
import json
import os
import sys

identity_id = os.environ["identity_id"]
configuration = {
    "location": os.environ["location"],
    "identity": {
        "type": "UserAssigned",
        "userAssignedIdentities": {identity_id: {}},
    },
    "properties": {
        "environmentId": os.environ["environment_id"],
        "workloadProfileName": "Consumption",
        "configuration": {
            "activeRevisionsMode": "Single",
            "ingress": {
                "external": True,
                "targetPort": 8080,
                "transport": "Auto",
                "allowInsecure": False,
                "traffic": [{"latestRevision": True, "weight": 100}],
            },
            "registries": [
                {
                    "server": os.environ["acr_login_server"],
                    "identity": identity_id,
                }
            ],
            "secrets": [
                {
                    "name": "classifier-api-key",
                    "value": os.environ["classifier_api_key"],
                }
            ],
        },
        "template": {
            "containers": [
                {
                    "name": "classifier-api",
                    "image": os.environ["api_image"],
                    "env": [
                        {
                            "name": "CLASSIFIER_API_KEY",
                            "secretRef": "classifier-api-key",
                        },
                        {
                            "name": "OLLAYA_URL",
                            "value": f"https://{os.environ['ollaya_fqdn']}",
                        },
                        {"name": "OLLAYA_MODEL", "value": "massive-classifier"},
                        {"name": "OLLAYA_TIMEOUT_MS", "value": "600000"},
                        {"name": "OLLAYA_REQUIRED_DEVICE", "value": "cuda"},
                        {"name": "ENABLE_AZURE", "value": os.environ["enable_azure"]},
                        {
                            "name": "AZURE_CLIENT_ID",
                            "value": os.environ["identity_client_id"],
                        },
                        {
                            "name": "AZURE_OPENAI_ENDPOINT",
                            "value": os.environ["nano_endpoint"],
                        },
                        {
                            "name": "AZURE_OPENAI_DEPLOYMENT",
                            "value": os.environ["nano_deployment"],
                        },
                        {"name": "AZURE_REASONING_EFFORT", "value": "none"},
                        {"name": "AZURE_TIMEOUT_MS", "value": "180000"},
                    ],
                    "resources": {"cpu": 0.5, "memory": "1Gi"},
                    "probes": [
                        {
                            "type": "Startup",
                            "httpGet": {"path": "/healthz", "port": 8080},
                            "initialDelaySeconds": 1,
                            "periodSeconds": 5,
                            "timeoutSeconds": 3,
                            "failureThreshold": 60,
                        },
                        {
                            "type": "Readiness",
                            "httpGet": {"path": "/readyz", "port": 8080},
                            "initialDelaySeconds": 1,
                            "periodSeconds": 10,
                            "timeoutSeconds": 30,
                            "failureThreshold": 3,
                        },
                    ],
                }
            ],
            "scale": {"minReplicas": 1, "maxReplicas": 1},
        },
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(configuration, handle)
PY

deploy_container_app "$api_app_name" "$resource_group" "$api_config"
api_revision="$(az containerapp show \
  --name "$api_app_name" \
  --resource-group "$resource_group" \
  --query properties.latestRevisionName \
  -o tsv \
  --only-show-errors)"
if [[ -z "$api_revision" ]]; then
  echo "The classifier API has no latest revision." >&2
  exit 1
fi
wait_revision_healthy \
  "$api_app_name" \
  "$resource_group" \
  "$api_revision" \
  "$model_ready_timeout_minutes"

api_fqdn="$(az containerapp show \
  --name "$api_app_name" \
  --resource-group "$resource_group" \
  --query properties.configuration.ingress.fqdn \
  -o tsv \
  --only-show-errors)"
if [[ -z "$api_fqdn" ]]; then
  echo "The classifier API has no external FQDN." >&2
  exit 1
fi

classifier_endpoint="https://$api_fqdn"
echo "Waiting for Winnow to download, load on the T4, and pass a real warm-up decision..."
ready_result=""
ready_deadline=$((SECONDS + model_ready_timeout_minutes * 60))
attempt=0
while (( SECONDS < ready_deadline )); do
  attempt=$((attempt + 1))
  if ready_result="$(curl --fail --silent --max-time 30 "$classifier_endpoint/readyz" 2>/dev/null)"; then
    if python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("status") == "ready" and str(r.get("device", "")).startswith("cuda:") and int(r.get("sizeVramBytes", 0)) > 0 else 1)' <<<"$ready_result"; then
      break
    fi
  fi
  if (( attempt % 12 == 0 )); then
    echo "Still waiting for Winnow readiness ($attempt attempts)..."
  fi
  sleep 10
done
if [[ -z "$ready_result" ]] || ! python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("status") == "ready" and str(r.get("device", "")).startswith("cuda:") and int(r.get("sizeVramBytes", 0)) > 0 else 1)' <<<"$ready_result"; then
  echo "Classifier API did not report CUDA readiness within $model_ready_timeout_minutes minutes." >&2
  exit 1
fi

sample_body='{"text":"set an alarm for seven tomorrow morning"}'
winnow_result="$(curl --fail --silent --max-time 180 \
  -H "Authorization: Bearer $classifier_api_key" \
  -H "Content-Type: application/json" \
  -d "$sample_body" \
  "$classifier_endpoint/v1/classify/winnow")"
winnow_intent="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["intent"]["label"])' <<<"$winnow_result")"

azure_intent=""
if [[ "$deployment_mode" == "full" ]]; then
  azure_result="$(curl --fail --silent --max-time 180 \
    -H "Authorization: Bearer $classifier_api_key" \
    -H "Content-Type: application/json" \
    -d "$sample_body" \
    "$classifier_endpoint/v1/classify/azure")"
  azure_intent="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["intent"]["label"])' <<<"$azure_result")"
else
  azure_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 180 \
    -H "Authorization: ******" \
    -H "Content-Type: application/json" \
    -d "$sample_body" \
    "$classifier_endpoint/v1/classify/azure")"
  if [[ "$azure_status" != "503" ]]; then
    echo "The Azure endpoint returned $azure_status in ollaya-only mode; expected 503." >&2
    exit 1
  fi
fi

workload_profile="$(az containerapp show \
  --name "$ollaya_app_name" \
  --resource-group "$resource_group" \
  --query properties.workloadProfileName \
  -o tsv \
  --only-show-errors)"
if [[ "$workload_profile" != "$gpu_workload_profile_name" ]]; then
  echo "Ollaya is using workload profile $workload_profile instead of $gpu_workload_profile_name." >&2
  exit 1
fi

azd env set CLASSIFIER_ENDPOINT "$classifier_endpoint" >/dev/null
python3 - "$repo_root/classifier.local.json" <<PY
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "endpoint": "$classifier_endpoint",
            "apiKey": "$classifier_api_key",
            "deploymentMode": "$deployment_mode",
        },
        handle,
        indent=2,
    )
    handle.write("\\n")
PY

echo
echo "Deployment complete."
echo "Classifier endpoint: $classifier_endpoint"
echo "Deployment mode: $deployment_mode"
echo "GPU workload profile: $workload_profile"
echo "Winnow device: $(python3 -c 'import json,sys; print(json.load(sys.stdin)["device"])' <<<"$ready_result")"
echo "Winnow VRAM bytes: $(python3 -c 'import json,sys; print(json.load(sys.stdin)["sizeVramBytes"])' <<<"$ready_result")"
echo "Winnow smoke-test intent: $winnow_intent"
if [[ -n "$azure_intent" ]]; then
  echo "GPT-5.4 Nano smoke-test intent: $azure_intent"
fi
echo "Local configuration: classifier.local.json"

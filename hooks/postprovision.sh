#!/usr/bin/env bash
set -euo pipefail

get_value() {
  azd env get-value "$1"
}

resource_group="$(get_value AZURE_RESOURCE_GROUP)"
environment_name="$(get_value AZURE_CONTAINER_APPS_ENVIRONMENT_NAME)"
acr_name="$(get_value ACR_NAME)"
acr_login_server="$(get_value ACR_LOGIN_SERVER)"
identity_id="$(get_value APP_IDENTITY_ID)"
identity_client_id="$(get_value APP_IDENTITY_CLIENT_ID)"
ollaya_app_name="$(get_value OLLAYA_APP_NAME)"
router_app_name="$(get_value ROUTER_APP_NAME)"
router_api_key="$(get_value ROUTER_API_KEY)"
luna_endpoint="$(get_value LUNA_ENDPOINT)"
luna_deployment="$(get_value LUNA_DEPLOYMENT)"
terra_endpoint="$(get_value TERRA_ENDPOINT)"
terra_deployment="$(get_value TERRA_DEPLOYMENT)"
sol_endpoint="$(get_value SOL_ENDPOINT)"
sol_deployment="$(get_value SOL_DEPLOYMENT)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_prefix="ollaya-on-aca"
image_tag="$(date -u +%Y%m%d%H%M%S)"

app_exists() {
  [ "$(az containerapp show --name "$1" --resource-group "$resource_group" --query properties.provisioningState -o tsv --only-show-errors 2>/dev/null || true)" = "Succeeded" ]
}

echo "Building the Ollaya and routing gateway images in Azure Container Registry..."
az acr build --registry "$acr_name" --image "$image_prefix/ollaya:$image_tag" --file "$repo_root/app/ollaya/Dockerfile" "$repo_root/app/ollaya" --only-show-errors
az acr build --registry "$acr_name" --image "$image_prefix/router:$image_tag" --file "$repo_root/app/router/Dockerfile" "$repo_root/app/router" --only-show-errors

ollaya_image="$acr_login_server/$image_prefix/ollaya:$image_tag"
router_image="$acr_login_server/$image_prefix/router:$image_tag"

if app_exists "$ollaya_app_name"; then
  az containerapp identity assign --name "$ollaya_app_name" --resource-group "$resource_group" --user-assigned "$identity_id" --only-show-errors >/dev/null
  az containerapp registry set --name "$ollaya_app_name" --resource-group "$resource_group" --server "$acr_login_server" --identity "$identity_id" --only-show-errors >/dev/null
  az containerapp update \
    --name "$ollaya_app_name" \
    --resource-group "$resource_group" \
    --image "$ollaya_image" \
    --cpu 2.0 \
    --memory 4Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --set-env-vars OLLAYA_KEEP_ALIVE=-1 OLLAYA_ROUTER_MODEL=coding-router \
    --only-show-errors >/dev/null
  az containerapp ingress enable --name "$ollaya_app_name" --resource-group "$resource_group" --type internal --target-port 11435 --transport auto --only-show-errors >/dev/null
else
  az containerapp create \
    --name "$ollaya_app_name" \
    --resource-group "$resource_group" \
    --environment "$environment_name" \
    --image "$ollaya_image" \
    --ingress internal \
    --target-port 11435 \
    --transport auto \
    --user-assigned "$identity_id" \
    --registry-server "$acr_login_server" \
    --registry-identity "$identity_id" \
    --cpu 2.0 \
    --memory 4Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --env-vars OLLAYA_KEEP_ALIVE=-1 OLLAYA_ROUTER_MODEL=coding-router \
    --only-show-errors >/dev/null
fi

ollaya_fqdn="$(az containerapp show --name "$ollaya_app_name" --resource-group "$resource_group" --query properties.configuration.ingress.fqdn -o tsv)"

if app_exists "$router_app_name"; then
  az containerapp identity assign --name "$router_app_name" --resource-group "$resource_group" --user-assigned "$identity_id" --only-show-errors >/dev/null
  az containerapp registry set --name "$router_app_name" --resource-group "$resource_group" --server "$acr_login_server" --identity "$identity_id" --only-show-errors >/dev/null
  az containerapp secret set --name "$router_app_name" --resource-group "$resource_group" --secrets router-api-key="$router_api_key" --only-show-errors >/dev/null
  az containerapp update \
    --name "$router_app_name" \
    --resource-group "$resource_group" \
    --image "$router_image" \
    --cpu 0.5 \
    --memory 1Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --set-env-vars \
      ROUTER_API_KEY=secretref:router-api-key \
      OLLAYA_URL="https://$ollaya_fqdn" \
      OLLAYA_MODEL=coding-router \
      OLLAYA_TIMEOUT_MS=120000 \
      AZURE_CLIENT_ID="$identity_client_id" \
      AZURE_LUNA_ENDPOINT="$luna_endpoint" \
      AZURE_LUNA_DEPLOYMENT="$luna_deployment" \
      AZURE_TERRA_ENDPOINT="$terra_endpoint" \
      AZURE_TERRA_DEPLOYMENT="$terra_deployment" \
      AZURE_SOL_ENDPOINT="$sol_endpoint" \
      AZURE_SOL_DEPLOYMENT="$sol_deployment" \
    --only-show-errors >/dev/null
  az containerapp ingress enable --name "$router_app_name" --resource-group "$resource_group" --type external --target-port 8080 --transport auto --only-show-errors >/dev/null
else
  az containerapp create \
    --name "$router_app_name" \
    --resource-group "$resource_group" \
    --environment "$environment_name" \
    --image "$router_image" \
    --ingress external \
    --target-port 8080 \
    --transport auto \
    --user-assigned "$identity_id" \
    --registry-server "$acr_login_server" \
    --registry-identity "$identity_id" \
    --cpu 0.5 \
    --memory 1Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --secrets router-api-key="$router_api_key" \
    --env-vars \
      ROUTER_API_KEY=secretref:router-api-key \
      OLLAYA_URL="https://$ollaya_fqdn" \
      OLLAYA_MODEL=coding-router \
      OLLAYA_TIMEOUT_MS=120000 \
      AZURE_CLIENT_ID="$identity_client_id" \
      AZURE_LUNA_ENDPOINT="$luna_endpoint" \
      AZURE_LUNA_DEPLOYMENT="$luna_deployment" \
      AZURE_TERRA_ENDPOINT="$terra_endpoint" \
      AZURE_TERRA_DEPLOYMENT="$terra_deployment" \
      AZURE_SOL_ENDPOINT="$sol_endpoint" \
      AZURE_SOL_DEPLOYMENT="$sol_deployment" \
    --only-show-errors >/dev/null
fi

router_fqdn="$(az containerapp show --name "$router_app_name" --resource-group "$resource_group" --query properties.configuration.ingress.fqdn -o tsv)"
router_endpoint="https://$router_fqdn"

echo "Waiting for Ollaya to pull Laya and create the coding router..."
for attempt in $(seq 1 60); do
  if curl --fail --silent "$router_endpoint/healthz" >/dev/null; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "Router did not become healthy." >&2
    exit 1
  fi
  sleep 5
done

route_result="$(curl --fail --silent \
  -H "Authorization: Bearer $router_api_key" \
  -H "Content-Type: application/json" \
  -d '{"input":"Rename the local variable x to count in one function."}' \
  "$router_endpoint/route")"
echo "$route_result" | grep -q '"route"'

generation_result=""
for attempt in $(seq 1 30); do
  if generation_result="$(curl --fail --silent --max-time 120 \
    -H "Authorization: Bearer $router_api_key" \
    -H "Content-Type: application/json" \
    -d '{"model":"ollaya-auto","input":"Reply with exactly the word ready.","max_output_tokens":32,"stream":false}' \
    "$router_endpoint/v1/responses")"; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "Azure OpenAI smoke test failed after 30 attempts." >&2
    exit 1
  fi
  sleep 10
done
echo "$generation_result" | grep -q '"id"'

azd env set ROUTER_ENDPOINT "$router_endpoint" >/dev/null

cat >"$repo_root/opencode.local.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollaya-aca/ollaya-auto",
  "provider": {
    "ollaya-aca": {
      "npm": "@ai-sdk/openai",
      "name": "Ollaya router on Azure Container Apps",
      "options": {
        "baseURL": "$router_endpoint/v1",
        "apiKey": "$router_api_key"
      },
      "models": {
        "ollaya-auto": {
          "name": "Ollaya automatic routing",
          "limit": { "context": 922000, "output": 128000 }
        },
        "ollaya-baseline": {
          "name": "GPT-5.6 Sol high reasoning baseline",
          "limit": { "context": 922000, "output": 128000 }
        }
      }
    }
  }
}
EOF

echo
echo "Deployment complete."
echo "Router endpoint: $router_endpoint"
echo "OpenCode config: opencode.local.json"

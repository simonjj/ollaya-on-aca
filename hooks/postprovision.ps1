$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Get-AzdValue([string]$Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Missing azd environment value: $Name"
    }
    return $value
}

function Test-ContainerApp([string]$Name, [string]$ResourceGroup) {
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $state = az containerapp show --name $Name --resource-group $ResourceGroup --query properties.provisioningState -o tsv --only-show-errors 2>$null
        $succeeded = $LASTEXITCODE -eq 0 -and $state -eq "Succeeded"
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    }
    return $succeeded
}

function Wait-Endpoint([string]$Uri, [hashtable]$Headers = @{}) {
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -TimeoutSec 10 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return
            }
        } catch {
            if ($attempt -eq 60) { throw }
        }
        Start-Sleep -Seconds 5
    }
    throw "Endpoint did not become ready: $Uri"
}

$resourceGroup = Get-AzdValue "AZURE_RESOURCE_GROUP"
$environmentName = Get-AzdValue "AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"
$acrName = Get-AzdValue "ACR_NAME"
$acrLoginServer = Get-AzdValue "ACR_LOGIN_SERVER"
$identityId = Get-AzdValue "APP_IDENTITY_ID"
$identityClientId = Get-AzdValue "APP_IDENTITY_CLIENT_ID"
$ollayaAppName = Get-AzdValue "OLLAYA_APP_NAME"
$routerAppName = Get-AzdValue "ROUTER_APP_NAME"
$routerApiKey = Get-AzdValue "ROUTER_API_KEY"
$lunaEndpoint = Get-AzdValue "LUNA_ENDPOINT"
$lunaDeployment = Get-AzdValue "LUNA_DEPLOYMENT"
$terraEndpoint = Get-AzdValue "TERRA_ENDPOINT"
$terraDeployment = Get-AzdValue "TERRA_DEPLOYMENT"
$solEndpoint = Get-AzdValue "SOL_ENDPOINT"
$solDeployment = Get-AzdValue "SOL_DEPLOYMENT"
$repoRoot = Split-Path -Parent $PSScriptRoot
$imagePrefix = "ollaya-on-aca"
$imageTag = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")

Write-Host "Building the Ollaya and routing gateway images in Azure Container Registry..."
az acr build --registry $acrName --image "$imagePrefix/ollaya:$imageTag" --file "$repoRoot\app\ollaya\Dockerfile" "$repoRoot\app\ollaya" --only-show-errors
az acr build --registry $acrName --image "$imagePrefix/router:$imageTag" --file "$repoRoot\app\router\Dockerfile" "$repoRoot\app\router" --only-show-errors

$ollayaImage = "$acrLoginServer/$imagePrefix/ollaya:$imageTag"
$routerImage = "$acrLoginServer/$imagePrefix/router:$imageTag"

if (-not (Test-ContainerApp $ollayaAppName $resourceGroup)) {
    az containerapp create `
        --name $ollayaAppName `
        --resource-group $resourceGroup `
        --environment $environmentName `
        --image $ollayaImage `
        --ingress internal `
        --target-port 11435 `
        --transport auto `
        --user-assigned $identityId `
        --registry-server $acrLoginServer `
        --registry-identity $identityId `
        --cpu 2.0 `
        --memory 4Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --env-vars OLLAYA_KEEP_ALIVE=-1 OLLAYA_ROUTER_MODEL=coding-router `
        --only-show-errors 1>$null
} else {
    az containerapp identity assign --name $ollayaAppName --resource-group $resourceGroup --user-assigned $identityId --only-show-errors 1>$null
    az containerapp registry set --name $ollayaAppName --resource-group $resourceGroup --server $acrLoginServer --identity $identityId --only-show-errors 1>$null
    az containerapp update `
        --name $ollayaAppName `
        --resource-group $resourceGroup `
        --image $ollayaImage `
        --cpu 2.0 `
        --memory 4Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --set-env-vars OLLAYA_KEEP_ALIVE=-1 OLLAYA_ROUTER_MODEL=coding-router `
        --only-show-errors 1>$null
    az containerapp ingress enable --name $ollayaAppName --resource-group $resourceGroup --type internal --target-port 11435 --transport auto --only-show-errors 1>$null
}

$ollayaFqdn = az containerapp show --name $ollayaAppName --resource-group $resourceGroup --query properties.configuration.ingress.fqdn -o tsv
if (-not $ollayaFqdn) { throw "The Ollaya app has no internal FQDN." }

if (-not (Test-ContainerApp $routerAppName $resourceGroup)) {
    az containerapp create `
        --name $routerAppName `
        --resource-group $resourceGroup `
        --environment $environmentName `
        --image $routerImage `
        --ingress external `
        --target-port 8080 `
        --transport auto `
        --user-assigned $identityId `
        --registry-server $acrLoginServer `
        --registry-identity $identityId `
        --cpu 0.5 `
        --memory 1Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --secrets router-api-key="$routerApiKey" `
        --env-vars `
            ROUTER_API_KEY=secretref:router-api-key `
            OLLAYA_URL="https://$ollayaFqdn" `
            OLLAYA_MODEL=coding-router `
            OLLAYA_TIMEOUT_MS=120000 `
            AZURE_CLIENT_ID=$identityClientId `
            AZURE_LUNA_ENDPOINT=$lunaEndpoint `
            AZURE_LUNA_DEPLOYMENT=$lunaDeployment `
            AZURE_TERRA_ENDPOINT=$terraEndpoint `
            AZURE_TERRA_DEPLOYMENT=$terraDeployment `
            AZURE_SOL_ENDPOINT=$solEndpoint `
            AZURE_SOL_DEPLOYMENT=$solDeployment `
        --only-show-errors 1>$null
} else {
    az containerapp identity assign --name $routerAppName --resource-group $resourceGroup --user-assigned $identityId --only-show-errors 1>$null
    az containerapp registry set --name $routerAppName --resource-group $resourceGroup --server $acrLoginServer --identity $identityId --only-show-errors 1>$null
    az containerapp secret set --name $routerAppName --resource-group $resourceGroup --secrets router-api-key="$routerApiKey" --only-show-errors 1>$null
    az containerapp update `
        --name $routerAppName `
        --resource-group $resourceGroup `
        --image $routerImage `
        --cpu 0.5 `
        --memory 1Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --set-env-vars `
            ROUTER_API_KEY=secretref:router-api-key `
            OLLAYA_URL="https://$ollayaFqdn" `
            OLLAYA_MODEL=coding-router `
            OLLAYA_TIMEOUT_MS=120000 `
            AZURE_CLIENT_ID=$identityClientId `
            AZURE_LUNA_ENDPOINT=$lunaEndpoint `
            AZURE_LUNA_DEPLOYMENT=$lunaDeployment `
            AZURE_TERRA_ENDPOINT=$terraEndpoint `
            AZURE_TERRA_DEPLOYMENT=$terraDeployment `
            AZURE_SOL_ENDPOINT=$solEndpoint `
            AZURE_SOL_DEPLOYMENT=$solDeployment `
        --only-show-errors 1>$null
    az containerapp ingress enable --name $routerAppName --resource-group $resourceGroup --type external --target-port 8080 --transport auto --only-show-errors 1>$null
}

$routerFqdn = az containerapp show --name $routerAppName --resource-group $resourceGroup --query properties.configuration.ingress.fqdn -o tsv
if (-not $routerFqdn) { throw "The router app has no external FQDN." }
$routerEndpoint = "https://$routerFqdn"
$headers = @{ Authorization = "Bearer $routerApiKey" }

Write-Host "Waiting for Ollaya to pull Laya and create the coding router..."
Wait-Endpoint "$routerEndpoint/healthz"

$routeBody = @{ input = "Rename the local variable x to count in one function." } | ConvertTo-Json
$routeResult = Invoke-RestMethod -Method Post -Uri "$routerEndpoint/route" -Headers $headers -ContentType "application/json" -Body $routeBody
if (-not $routeResult.route) { throw "The route smoke test did not return a route." }

$generationBody = @{
    model = "ollaya-auto"
    input = "Reply with exactly the word ready."
    max_output_tokens = 32
    stream = $false
} | ConvertTo-Json -Depth 5

$generationResult = $null
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $generationResult = Invoke-RestMethod -Method Post -Uri "$routerEndpoint/v1/responses" -Headers $headers -ContentType "application/json" -Body $generationBody -TimeoutSec 120
        break
    } catch {
        if ($attempt -eq 30) { throw }
        Start-Sleep -Seconds 10
    }
}
if (-not $generationResult.id) { throw "The Azure OpenAI smoke test did not return a response id." }

azd env set ROUTER_ENDPOINT $routerEndpoint | Out-Null

$config = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "model": "ollaya-aca/ollaya-auto",
  "provider": {
    "ollaya-aca": {
      "npm": "@ai-sdk/openai",
      "name": "Ollaya router on Azure Container Apps",
      "options": {
        "baseURL": "$routerEndpoint/v1",
        "apiKey": "$routerApiKey"
      },
      "models": {
        "ollaya-auto": {
          "name": "Ollaya automatic routing",
          "limit": {
            "context": 922000,
            "output": 128000
          }
        },
        "ollaya-baseline": {
          "name": "GPT-5.6 Sol high reasoning baseline",
          "limit": {
            "context": 922000,
            "output": 128000
          }
        }
      }
    }
  }
}
"@
$config | Set-Content -Path "$repoRoot\opencode.local.json" -Encoding UTF8

Write-Host ""
Write-Host "Deployment complete."
Write-Host "Router endpoint: $routerEndpoint"
Write-Host "Ollaya smoke-test route: $($routeResult.route)"
Write-Host "OpenCode config: opencode.local.json"

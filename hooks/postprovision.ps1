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
        az containerapp show --name $Name --resource-group $ResourceGroup --only-show-errors 1>$null 2>$null
        return $LASTEXITCODE -eq 0
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    }
}

function Deploy-ContainerApp(
    [string]$Name,
    [string]$ResourceGroup,
    [string]$ConfigurationPath
) {
    if (Test-ContainerApp $Name $ResourceGroup) {
        az containerapp update `
            --name $Name `
            --resource-group $ResourceGroup `
            --yaml $ConfigurationPath `
            --only-show-errors 1>$null
    } else {
        az containerapp create `
            --name $Name `
            --resource-group $ResourceGroup `
            --yaml $ConfigurationPath `
            --only-show-errors 1>$null
    }
}

function Wait-Ready([string]$Uri, [int]$TimeoutMinutes) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $response = Invoke-RestMethod -Uri $Uri -TimeoutSec 30
            if (
                $response.status -eq "ready" -and
                $response.device -like "cuda:*" -and
                [long]$response.sizeVramBytes -gt 0
            ) {
                return $response
            }
        } catch {}
        if ($attempt % 12 -eq 0) {
            Write-Host "Still waiting for Winnow readiness ($attempt attempts)..."
        }
        Start-Sleep -Seconds 10
    }
    throw "Endpoint did not report CUDA readiness within $TimeoutMinutes minutes: $Uri"
}

function Wait-RevisionHealthy(
    [string]$Name,
    [string]$ResourceGroup,
    [string]$Revision,
    [int]$TimeoutMinutes
) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $state = az containerapp revision show `
            --name $Name `
            --resource-group $ResourceGroup `
            --revision $Revision `
            --query "{health:properties.healthState,running:properties.runningState}" `
            -o json `
            --only-show-errors | ConvertFrom-Json
        if ($state.health -eq "Healthy" -and $state.running -eq "RunningAtMaxScale") {
            return
        }
        Start-Sleep -Seconds 10
    }
    throw "Revision $Revision did not become healthy within $TimeoutMinutes minutes."
}

$resourceGroup = Get-AzdValue "AZURE_RESOURCE_GROUP"
$location = Get-AzdValue "AZURE_LOCATION"
$deploymentMode = Get-AzdValue "DEPLOYMENT_MODE"
$environmentId = Get-AzdValue "AZURE_CONTAINER_APPS_ENVIRONMENT_ID"
$acrName = Get-AzdValue "ACR_NAME"
$acrLoginServer = Get-AzdValue "ACR_LOGIN_SERVER"
$identityId = Get-AzdValue "APP_IDENTITY_ID"
$identityClientId = Get-AzdValue "APP_IDENTITY_CLIENT_ID"
$ollayaAppName = Get-AzdValue "OLLAYA_APP_NAME"
$apiAppName = Get-AzdValue "CLASSIFIER_API_APP_NAME"
$modelStorageName = Get-AzdValue "MODEL_STORAGE_NAME"
$gpuWorkloadProfileName = Get-AzdValue "GPU_WORKLOAD_PROFILE_NAME"
$classifierApiKey = Get-AzdValue "CLASSIFIER_API_KEY"
$gpuMinReplicas = [int](Get-AzdValue "GPU_MIN_REPLICAS")
$modelReadyTimeoutMinutes = [int](Get-AzdValue "MODEL_READY_TIMEOUT_MINUTES")
$nanoEndpoint = ""
$nanoDeployment = ""
if ($deploymentMode -eq "full") {
    $nanoEndpoint = Get-AzdValue "NANO_ENDPOINT"
    $nanoDeployment = Get-AzdValue "NANO_DEPLOYMENT"
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$imagePrefix = "ollaya-on-aca"
$imageTag = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ollaya-on-aca-$imageTag"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Write-Host "Building immutable Ollaya and classifier API images..."
    az acr build `
        --registry $acrName `
        --image "$imagePrefix/ollaya:$imageTag" `
        --file "$repoRoot\app\ollaya\Dockerfile" `
        $repoRoot `
        --only-show-errors
    az acr build `
        --registry $acrName `
        --image "$imagePrefix/api:$imageTag" `
        --file "$repoRoot\app\api\Dockerfile" `
        $repoRoot `
        --only-show-errors

    $ollayaImage = "$acrLoginServer/$imagePrefix/ollaya:$imageTag"
    $apiImage = "$acrLoginServer/$imagePrefix/api:$imageTag"
    $userAssignedIdentities = @{}
    $userAssignedIdentities[$identityId] = @{}

    $ollayaConfiguration = @{
        location = $location
        identity = @{
            type = "UserAssigned"
            userAssignedIdentities = $userAssignedIdentities
        }
        properties = @{
            environmentId = $environmentId
            workloadProfileName = $gpuWorkloadProfileName
            configuration = @{
                activeRevisionsMode = "Single"
                ingress = @{
                    external = $false
                    targetPort = 11435
                    transport = "Auto"
                    allowInsecure = $false
                    traffic = @(
                        @{
                            latestRevision = $true
                            weight = 100
                        }
                    )
                }
                registries = @(
                    @{
                        server = $acrLoginServer
                        identity = $identityId
                    }
                )
            }
            template = @{
                containers = @(
                    @{
                        name = "ollaya"
                        image = $ollayaImage
                        env = @(
                            @{ name = "OLLAYA_BASE_MODEL"; value = "winnow:e4b" }
                            @{ name = "OLLAYA_MODEL"; value = "massive-classifier" }
                            @{ name = "OLLAYA_KEEP_ALIVE"; value = "-1" }
                            @{ name = "OLLAYA_DEVICE"; value = "cuda" }
                        )
                        resources = @{
                            cpu = 8.0
                            memory = "56Gi"
                        }
                        volumeMounts = @(
                            @{
                                volumeName = "ollaya-models"
                                mountPath = "/home/ollaya/.ollaya/models"
                            }
                        )
                    }
                )
                scale = @{
                    minReplicas = $gpuMinReplicas
                    maxReplicas = 1
                }
                volumes = @(
                    @{
                        name = "ollaya-models"
                        storageType = "AzureFile"
                        storageName = $modelStorageName
                    }
                )
            }
        }
    }
    $ollayaConfigPath = Join-Path $tempRoot "ollaya.json"
    $ollayaConfiguration | ConvertTo-Json -Depth 30 | Set-Content $ollayaConfigPath -Encoding utf8NoBOM
    Deploy-ContainerApp $ollayaAppName $resourceGroup $ollayaConfigPath

    $ollayaFqdn = az containerapp show `
        --name $ollayaAppName `
        --resource-group $resourceGroup `
        --query properties.configuration.ingress.fqdn `
        -o tsv `
        --only-show-errors
    if (-not $ollayaFqdn) { throw "The Ollaya app has no internal FQDN." }

    $apiSecrets = @(
        @{
            name = "classifier-api-key"
            value = $classifierApiKey
        }
    )
    $apiEnvironment = @(
        @{ name = "CLASSIFIER_API_KEY"; secretRef = "classifier-api-key" }
        @{ name = "OLLAYA_URL"; value = "https://$ollayaFqdn" }
        @{ name = "OLLAYA_MODEL"; value = "massive-classifier" }
        @{ name = "OLLAYA_TIMEOUT_MS"; value = "600000" }
        @{ name = "OLLAYA_REQUIRED_DEVICE"; value = "cuda" }
        @{ name = "ENABLE_AZURE"; value = ($deploymentMode -eq "full").ToString().ToLowerInvariant() }
        @{ name = "AZURE_CLIENT_ID"; value = $identityClientId }
        @{ name = "AZURE_OPENAI_ENDPOINT"; value = $nanoEndpoint }
        @{ name = "AZURE_OPENAI_DEPLOYMENT"; value = $nanoDeployment }
        @{ name = "AZURE_REASONING_EFFORT"; value = "none" }
        @{ name = "AZURE_TIMEOUT_MS"; value = "180000" }
    )
    $apiConfiguration = @{
        location = $location
        identity = @{
            type = "UserAssigned"
            userAssignedIdentities = $userAssignedIdentities
        }
        properties = @{
            environmentId = $environmentId
            workloadProfileName = "Consumption"
            configuration = @{
                activeRevisionsMode = "Single"
                ingress = @{
                    external = $true
                    targetPort = 8080
                    transport = "Auto"
                    allowInsecure = $false
                    traffic = @(
                        @{
                            latestRevision = $true
                            weight = 100
                        }
                    )
                }
                registries = @(
                    @{
                        server = $acrLoginServer
                        identity = $identityId
                    }
                )
                secrets = $apiSecrets
            }
            template = @{
                containers = @(
                    @{
                        name = "classifier-api"
                        image = $apiImage
                        env = $apiEnvironment
                        resources = @{
                            cpu = 0.5
                            memory = "1Gi"
                        }
                        probes = @(
                            @{
                                type = "Startup"
                                httpGet = @{ path = "/healthz"; port = 8080 }
                                initialDelaySeconds = 1
                                periodSeconds = 5
                                timeoutSeconds = 3
                                failureThreshold = 60
                            }
                            @{
                                type = "Readiness"
                                httpGet = @{ path = "/readyz"; port = 8080 }
                                initialDelaySeconds = 1
                                periodSeconds = 10
                                timeoutSeconds = 30
                                failureThreshold = 3
                            }
                        )
                    }
                )
                scale = @{
                    minReplicas = 1
                    maxReplicas = 1
                }
            }
        }
    }
    $apiConfigPath = Join-Path $tempRoot "api.json"
    $apiConfiguration | ConvertTo-Json -Depth 30 | Set-Content $apiConfigPath -Encoding utf8NoBOM
    Deploy-ContainerApp $apiAppName $resourceGroup $apiConfigPath
    $apiRevision = az containerapp show `
        --name $apiAppName `
        --resource-group $resourceGroup `
        --query properties.latestRevisionName `
        -o tsv `
        --only-show-errors
    if (-not $apiRevision) { throw "The classifier API has no latest revision." }
    Wait-RevisionHealthy $apiAppName $resourceGroup $apiRevision $modelReadyTimeoutMinutes

    $apiFqdn = az containerapp show `
        --name $apiAppName `
        --resource-group $resourceGroup `
        --query properties.configuration.ingress.fqdn `
        -o tsv `
        --only-show-errors
    if (-not $apiFqdn) { throw "The classifier API has no external FQDN." }
    $classifierEndpoint = "https://$apiFqdn"
    $headers = @{ Authorization = "Bearer $classifierApiKey" }

    Write-Host "Waiting for Winnow to download, load on the T4, and pass a real warm-up decision..."
    $ready = Wait-Ready "$classifierEndpoint/readyz" $modelReadyTimeoutMinutes

    $sampleBody = @{ text = "set an alarm for seven tomorrow morning" } | ConvertTo-Json
    $winnowResult = Invoke-RestMethod `
        -Method Post `
        -Uri "$classifierEndpoint/v1/classify/winnow" `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $sampleBody `
        -TimeoutSec 180
    if (-not $winnowResult.intent.label) {
        throw "The Winnow smoke test did not return an intent."
    }

    $azureIntent = $null
    if ($deploymentMode -eq "full") {
        $azureResult = Invoke-RestMethod `
            -Method Post `
            -Uri "$classifierEndpoint/v1/classify/azure" `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $sampleBody `
            -TimeoutSec 180
        if (-not $azureResult.intent.label) {
            throw "The GPT-5.4 Nano smoke test did not return an intent."
        }
        $azureIntent = $azureResult.intent.label
    } else {
        $azureResponse = Invoke-WebRequest `
            -Method Post `
            -Uri "$classifierEndpoint/v1/classify/azure" `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $sampleBody `
            -SkipHttpErrorCheck `
            -TimeoutSec 180
        if ([int]$azureResponse.StatusCode -ne 503) {
            throw "The Azure endpoint returned $($azureResponse.StatusCode) in ollaya-only mode; expected 503."
        }
    }

    $workloadProfile = az containerapp show `
        --name $ollayaAppName `
        --resource-group $resourceGroup `
        --query properties.workloadProfileName `
        -o tsv `
        --only-show-errors
    if ($workloadProfile -ne $gpuWorkloadProfileName) {
        throw "Ollaya is using workload profile $workloadProfile instead of $gpuWorkloadProfileName."
    }

    azd env set CLASSIFIER_ENDPOINT $classifierEndpoint | Out-Null
    $localConfiguration = @{
        endpoint = $classifierEndpoint
        apiKey = $classifierApiKey
        deploymentMode = $deploymentMode
    }
    $localConfiguration | ConvertTo-Json -Depth 5 | Set-Content `
        (Join-Path $repoRoot "classifier.local.json") `
        -Encoding utf8NoBOM

    Write-Host ""
    Write-Host "Deployment complete."
    Write-Host "Classifier endpoint: $classifierEndpoint"
    Write-Host "Deployment mode: $deploymentMode"
    Write-Host "GPU workload profile: $workloadProfile"
    Write-Host "Winnow warm-up: $($ready.warmupDurationMs) ms"
    Write-Host "Winnow device: $($ready.device)"
    Write-Host "Winnow VRAM bytes: $($ready.sizeVramBytes)"
    Write-Host "Winnow smoke-test intent: $($winnowResult.intent.label)"
    if ($azureIntent) {
        Write-Host "GPT-5.4 Nano smoke-test intent: $azureIntent"
    }
    Write-Host "Local configuration: classifier.local.json"
} finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

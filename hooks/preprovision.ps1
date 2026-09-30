$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Get-AzdValue([string]$Name) {
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $value = azd env get-value $Name 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $value
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    }
}

function Set-Default([string]$Name, [string]$Value) {
    if (-not (Get-AzdValue $Name)) {
        azd env set $Name $Value | Out-Null
    }
}

Set-Default "AZURE_LOCATION" "southcentralus"
Set-Default "DEPLOYMENT_MODE" "full"
Set-Default "NANO_CAPACITY" "100"
Set-Default "GPU_MIN_REPLICAS" "1"
Set-Default "MODEL_READY_TIMEOUT_MINUTES" "120"

$deploymentMode = Get-AzdValue "DEPLOYMENT_MODE"
if ($deploymentMode -notin @("full", "ollaya-only")) {
    throw "DEPLOYMENT_MODE must be full or ollaya-only."
}

if (-not (Get-AzdValue "CLASSIFIER_API_KEY")) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $key = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    azd env set CLASSIFIER_API_KEY $key | Out-Null
}

$gpuProfile = az containerapp env workload-profile list-supported `
    --location southcentralus `
    --query "[?name=='Consumption-GPU-NC8as-T4'].name | [0]" `
    -o tsv `
    --only-show-errors
if ($gpuProfile -ne "Consumption-GPU-NC8as-T4") {
    throw "Consumption-GPU-NC8as-T4 is not available in South Central US for this subscription."
}

if ($deploymentMode -eq "full") {
    $nanoLimit = az cognitiveservices usage list `
        --location eastus2 `
        --query "[?name.value=='OpenAI.GlobalStandard.gpt-5.4-nano'].limit | [0]" `
        -o tsv `
        --only-show-errors
    if (-not $nanoLimit -or [double]$nanoLimit -le 0) {
        throw "GPT-5.4 Nano Global Standard quota is unavailable in East US 2."
    }
    $nanoCapacity = [int](Get-AzdValue "NANO_CAPACITY")
    if ($nanoCapacity -gt [double]$nanoLimit) {
        throw "NANO_CAPACITY $nanoCapacity exceeds the available quota limit $nanoLimit."
    }
}

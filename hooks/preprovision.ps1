$ErrorActionPreference = "Stop"

function Get-AzdValue([string]$Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $value
}

if (-not (Get-AzdValue "AZURE_LOCATION")) {
    azd env set AZURE_LOCATION southcentralus | Out-Null
}
if (-not (Get-AzdValue "LUNA_CAPACITY")) {
    azd env set LUNA_CAPACITY 10 | Out-Null
}
if (-not (Get-AzdValue "TERRA_CAPACITY")) {
    azd env set TERRA_CAPACITY 10 | Out-Null
}
if (-not (Get-AzdValue "SOL_CAPACITY")) {
    azd env set SOL_CAPACITY 10 | Out-Null
}
if (-not (Get-AzdValue "ROUTER_API_KEY")) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $key = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    azd env set ROUTER_API_KEY $key | Out-Null
}

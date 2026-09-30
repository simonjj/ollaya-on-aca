targetScope = 'resourceGroup'

@description('Location for Azure Container Apps resources')
param location string

@description('Name of the azd environment')
param environmentName string

@description('Short deterministic suffix for globally unique resources')
param resourceToken string

@allowed([
  'full'
  'ollaya-only'
])
@description('Resources to deploy')
param deploymentMode string

@description('Global Standard capacity for GPT-5.4 Nano')
param nanoCapacity int

var deployAzure = deploymentMode == 'full'
var baseName = toLower('${environmentName}-${resourceToken}')
var compactName = replace(baseName, '-', '')
var containerAppsEnvironmentName = 'cae-${baseName}'
var logAnalyticsWorkspaceName = 'log-${baseName}'
var acrName = take('acrollaya${compactName}', 50)
var storageAccountName = take('stollaya${compactName}', 24)
var identityName = 'id-${baseName}'
var nanoAccountName = take('oai-nano-${baseName}', 64)
var nanoDeploymentName = 'gpt-5.4-nano'
var ollayaAppName = 'ollaya-${baseName}'
var apiAppName = 'classifier-${baseName}'
var modelStorageName = 'ollaya-models'
var modelShareName = 'ollaya-models'
var gpuWorkloadProfileName = 'gpu-t4'

var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: containerAppsEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: listKeys(logAnalyticsWorkspace.id, '2020-08-01').primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        name: gpuWorkloadProfileName
        workloadProfileType: 'Consumption-GPU-NC8as-T4'
      }
    ]
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource modelShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: modelShareName
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 64
  }
}

resource modelStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  parent: containerAppsEnvironment
  name: modelStorageName
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: modelShare.name
      accessMode: 'ReadWrite'
    }
  }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: containerRegistry
  name: guid(containerRegistry.id, appIdentity.id, acrPullRoleId)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource nanoAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = if (deployAzure) {
  name: nanoAccountName
  location: 'eastus2'
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'None'
  }
  properties: {
    customSubDomainName: nanoAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource nanoDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (deployAzure) {
  parent: nanoAccount
  name: nanoDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: nanoCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-nano'
      version: '2026-03-17'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource nanoInferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAzure) {
  scope: nanoAccount
  name: guid(nanoAccount.id, appIdentity.id, cognitiveServicesOpenAIUserRoleId)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

output ACR_NAME string = containerRegistry.name
output ACR_LOGIN_SERVER string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = containerAppsEnvironment.id
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = containerAppsEnvironment.name
output APP_IDENTITY_ID string = appIdentity.id
output APP_IDENTITY_CLIENT_ID string = appIdentity.properties.clientId
output OLLAYA_APP_NAME string = ollayaAppName
output CLASSIFIER_API_APP_NAME string = apiAppName
output MODEL_STORAGE_NAME string = modelStorage.name
output GPU_WORKLOAD_PROFILE_NAME string = gpuWorkloadProfileName
output NANO_ENDPOINT string = deployAzure ? nanoAccount!.properties.endpoint : ''
output NANO_DEPLOYMENT string = deployAzure ? nanoDeployment!.name : ''

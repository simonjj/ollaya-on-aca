targetScope = 'resourceGroup'

@description('Location for Azure Container Apps resources')
param location string

@description('Name of the azd environment')
param environmentName string

@description('Short deterministic suffix for globally unique resources')
param resourceToken string

@description('Global Standard capacity for GPT-5.6 Luna')
param lunaCapacity int

@description('Global Standard capacity for GPT-5.6 Terra')
param terraCapacity int

@description('Global Standard capacity for GPT-5.6 Sol')
param solCapacity int

var baseName = toLower('${environmentName}-${resourceToken}')
var compactName = replace(baseName, '-', '')
var containerAppsEnvironmentName = 'cae-${baseName}'
var logAnalyticsWorkspaceName = 'log-${baseName}'
var acrName = take('acrollaya${compactName}', 50)
var identityName = 'id-${baseName}'
var lunaAccountName = take('oai-luna-${baseName}', 64)
var solAccountName = take('oai-sol-${baseName}', 64)
var lunaDeploymentName = 'gpt-5.6-luna'
var terraDeploymentName = 'gpt-5.6-terra'
var solDeploymentName = 'gpt-5.6-sol'
var ollayaAppName = 'ollaya-${baseName}'
var routerAppName = 'router-${baseName}'

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

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
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

resource lunaAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: lunaAccountName
  location: 'eastus2'
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'None'
  }
  properties: {
    customSubDomainName: lunaAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource lunaDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: lunaAccount
  name: lunaDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: lunaCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.6-luna'
      version: '2026-07-09'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource solAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: solAccountName
  location: 'westus'
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'None'
  }
  properties: {
    customSubDomainName: solAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource solDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: solAccount
  name: solDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: solCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.6-sol'
      version: '2026-07-09'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource terraDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: solAccount
  name: terraDeploymentName
  dependsOn: [
    solDeployment
  ]
  sku: {
    name: 'GlobalStandard'
    capacity: terraCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.6-terra'
      version: '2026-07-09'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource lunaInferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: lunaAccount
  name: guid(lunaAccount.id, appIdentity.id, cognitiveServicesOpenAIUserRoleId)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

resource solInferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: solAccount
  name: guid(solAccount.id, appIdentity.id, cognitiveServicesOpenAIUserRoleId)
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
output ROUTER_APP_NAME string = routerAppName
output LUNA_ENDPOINT string = lunaAccount.properties.endpoint
output LUNA_DEPLOYMENT string = lunaDeployment.name
output TERRA_ENDPOINT string = solAccount.properties.endpoint
output TERRA_DEPLOYMENT string = terraDeployment.name
output SOL_ENDPOINT string = solAccount.properties.endpoint
output SOL_DEPLOYMENT string = solDeployment.name

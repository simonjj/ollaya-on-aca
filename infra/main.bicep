targetScope = 'resourceGroup'

@description('Name of the azd environment used for resource naming')
param environmentName string

@description('Primary location for Azure Container Apps resources')
param location string = 'southcentralus'

@description('Global Standard capacity for the GPT-5.6 Luna deployment')
param lunaCapacity int = 10

@description('Global Standard capacity for the GPT-5.6 Terra deployment')
param terraCapacity int = 10

@description('Global Standard capacity for the GPT-5.6 Sol deployment')
param solCapacity int = 10

var resourceToken = take(toLower(uniqueString(subscription().id, resourceGroup().id, environmentName)), 6)

module resources 'resources.bicep' = {
  name: 'resources'
  params: {
    environmentName: environmentName
    location: location
    resourceToken: resourceToken
    lunaCapacity: lunaCapacity
    terraCapacity: terraCapacity
    solCapacity: solCapacity
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output ACR_NAME string = resources.outputs.ACR_NAME
output ACR_LOGIN_SERVER string = resources.outputs.ACR_LOGIN_SERVER
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = resources.outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_NAME
output APP_IDENTITY_ID string = resources.outputs.APP_IDENTITY_ID
output APP_IDENTITY_CLIENT_ID string = resources.outputs.APP_IDENTITY_CLIENT_ID
output OLLAYA_APP_NAME string = resources.outputs.OLLAYA_APP_NAME
output ROUTER_APP_NAME string = resources.outputs.ROUTER_APP_NAME
output LUNA_ENDPOINT string = resources.outputs.LUNA_ENDPOINT
output LUNA_DEPLOYMENT string = resources.outputs.LUNA_DEPLOYMENT
output TERRA_ENDPOINT string = resources.outputs.TERRA_ENDPOINT
output TERRA_DEPLOYMENT string = resources.outputs.TERRA_DEPLOYMENT
output SOL_ENDPOINT string = resources.outputs.SOL_ENDPOINT
output SOL_DEPLOYMENT string = resources.outputs.SOL_DEPLOYMENT

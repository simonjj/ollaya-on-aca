targetScope = 'resourceGroup'

@description('Name of the azd environment used for resource naming')
param environmentName string

@description('Primary location for Azure Container Apps resources')
param location string = 'southcentralus'

@allowed([
  'full'
  'ollaya-only'
])
@description('Deploy the full benchmark or only the authenticated Winnow endpoint')
param deploymentMode string = 'full'

@description('Global Standard capacity for the GPT-5.4 Nano deployment')
param nanoCapacity int = 100

var resourceToken = take(toLower(uniqueString(subscription().id, resourceGroup().id, environmentName)), 6)

module resources 'resources.bicep' = {
  name: 'resources'
  params: {
    environmentName: environmentName
    location: location
    resourceToken: resourceToken
    deploymentMode: deploymentMode
    nanoCapacity: nanoCapacity
  }
}

output AZURE_LOCATION string = location
output DEPLOYMENT_MODE string = deploymentMode
output AZURE_TENANT_ID string = tenant().tenantId
output ACR_NAME string = resources.outputs.ACR_NAME
output ACR_LOGIN_SERVER string = resources.outputs.ACR_LOGIN_SERVER
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = resources.outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_NAME
output APP_IDENTITY_ID string = resources.outputs.APP_IDENTITY_ID
output APP_IDENTITY_CLIENT_ID string = resources.outputs.APP_IDENTITY_CLIENT_ID
output OLLAYA_APP_NAME string = resources.outputs.OLLAYA_APP_NAME
output CLASSIFIER_API_APP_NAME string = resources.outputs.CLASSIFIER_API_APP_NAME
output MODEL_STORAGE_NAME string = resources.outputs.MODEL_STORAGE_NAME
output GPU_WORKLOAD_PROFILE_NAME string = resources.outputs.GPU_WORKLOAD_PROFILE_NAME
output NANO_ENDPOINT string = resources.outputs.NANO_ENDPOINT
output NANO_DEPLOYMENT string = resources.outputs.NANO_DEPLOYMENT

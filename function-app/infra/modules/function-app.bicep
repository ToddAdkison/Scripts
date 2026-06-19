targetScope = 'resourceGroup'

param parLocation string
param parEnvironment string
param parUniqueSuffix string
param parStorageAccountName string
param parAppInsightsConnectionString string
param parTimerSchedule string
param parKqlQuery string
param parSharePointSiteId string
param parSharePointDriveId string
param parSharePointParentFolderId string
param parTags object

var varFunctionAppName = 'func-defxdr-${parEnvironment}-${parUniqueSuffix}'
var varHostingPlanName = 'plan-defxdr-${parEnvironment}-${parUniqueSuffix}'

resource resStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: parStorageAccountName
}

// Flex Consumption plan — uses FC1 SKU, not Y1 (Consumption) or EP1 (Premium)
resource resHostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: varHostingPlanName
  location: parLocation
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true  // Required for Linux
  }
  tags: parTags
}

resource resFunctionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: varFunctionAppName
  location: parLocation
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: resHostingPlan.id
    // functionAppConfig is the Flex Consumption-specific config block
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${resStorage.properties.primaryEndpoints.blob}deployments'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 10
        instanceMemoryMB: 2048  // Valid values: 512, 2048, 4096
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${parStorageAccountName};AccountKey=${resStorage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: parAppInsightsConnectionString
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'TIMER_SCHEDULE'
          value: parTimerSchedule
        }
        {
          name: 'KQL_QUERY'
          value: parKqlQuery
        }
        {
          name: 'SHAREPOINT_SITE_ID'
          value: parSharePointSiteId
        }
        {
          name: 'SHAREPOINT_DRIVE_ID'
          value: parSharePointDriveId
        }
        {
          name: 'SHAREPOINT_PARENT_FOLDER_ID'
          value: parSharePointParentFolderId
        }
      ]
    }
  }
  tags: parTags
}

output outFunctionAppName string = resFunctionApp.name
output outManagedIdentityPrincipalId string = resFunctionApp.identity.principalId
output outFunctionAppHostname string = resFunctionApp.properties.defaultHostName

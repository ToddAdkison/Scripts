targetScope = 'resourceGroup'

param parLocation string
param parUniqueSuffix string
param parTags object

resource resStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Max 24 chars, lowercase alphanumeric only
  name: 'stdefxdr${parUniqueSuffix}'
  location: parLocation
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Flex Consumption runtime requires shared key access for AzureWebJobsStorage
    allowSharedKeyAccess: true
  }
  tags: parTags
}

output outStorageAccountName string = resStorage.name
output outStorageAccountId string = resStorage.id
output outPrimaryEndpoints object = resStorage.properties.primaryEndpoints

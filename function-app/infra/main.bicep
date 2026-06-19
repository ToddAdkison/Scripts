targetScope = 'resourceGroup'

@description('Azure region for all resources')
param parLocation string = resourceGroup().location

@description('Environment name (dev, prod)')
@allowed(['dev', 'prod'])
param parEnvironment string

@description('Short unique suffix for globally unique resource names (4-6 alphanumeric chars)')
param parUniqueSuffix string

@description('NCRONTAB schedule expression — 6-field Azure Functions format: {sec} {min} {hr} {dom} {mon} {dow}')
param parTimerSchedule string = '0 0 6 * * *'

@description('KQL query to execute against Defender XDR Advanced Hunting (single-line)')
param parKqlQuery string

@description('SharePoint site ID (format: tenant.sharepoint.com,siteGuid,webGuid)')
param parSharePointSiteId string

@description('SharePoint document library drive GUID')
param parSharePointDriveId string

@description('SharePoint parent folder item ID — use "root" for the library root')
param parSharePointParentFolderId string = 'root'

param parTags object = {
  environment: parEnvironment
  managedBy: 'Bicep'
  workload: 'defender-xdr-report'
}

module modStorage 'modules/storage.bicep' = {
  name: 'deploy-storage'
  params: {
    parLocation: parLocation
    parUniqueSuffix: parUniqueSuffix
    parTags: parTags
  }
}

module modAppInsights 'modules/app-insights.bicep' = {
  name: 'deploy-app-insights'
  params: {
    parLocation: parLocation
    parEnvironment: parEnvironment
    parTags: parTags
  }
}

module modFunctionApp 'modules/function-app.bicep' = {
  name: 'deploy-function-app'
  params: {
    parLocation: parLocation
    parEnvironment: parEnvironment
    parUniqueSuffix: parUniqueSuffix
    parStorageAccountName: modStorage.outputs.outStorageAccountName
    parAppInsightsConnectionString: modAppInsights.outputs.outConnectionString
    parTimerSchedule: parTimerSchedule
    parKqlQuery: parKqlQuery
    parSharePointSiteId: parSharePointSiteId
    parSharePointDriveId: parSharePointDriveId
    parSharePointParentFolderId: parSharePointParentFolderId
    parTags: parTags
  }
}

output outFunctionAppName string = modFunctionApp.outputs.outFunctionAppName
output outManagedIdentityPrincipalId string = modFunctionApp.outputs.outManagedIdentityPrincipalId
output outStorageAccountName string = modStorage.outputs.outStorageAccountName
output outAppInsightsName string = modAppInsights.outputs.outAppInsightsName

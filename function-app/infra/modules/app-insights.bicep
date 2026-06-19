targetScope = 'resourceGroup'

param parLocation string
param parEnvironment string
param parTags object

// Workspace-based App Insights — classic App Insights is deprecated
resource resLogAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-defxdr-${parEnvironment}'
  location: parLocation
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
  tags: parTags
}

resource resAppInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-defxdr-${parEnvironment}'
  location: parLocation
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: resLogAnalytics.id
    RetentionInDays: 30
  }
  tags: parTags
}

output outConnectionString string = resAppInsights.properties.ConnectionString
output outAppInsightsId string = resAppInsights.id
output outAppInsightsName string = resAppInsights.name

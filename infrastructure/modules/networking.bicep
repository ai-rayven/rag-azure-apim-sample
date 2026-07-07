import { Tags } from '../types.bicep'

@description('Azure region for APIM and gateway observability.')
param location string

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

@description('APIM publisher email (any address you own).')
param publisherEmail string

@description('Resource ID of the central Log Analytics workspace (from rg-monitoring). Gateway App Insights and APIM diagnostics both flow here.')
param logAnalyticsWorkspaceId string

@description('Token streaming toggle')
param enableStreaming bool

// ---------- Gateway-tier App Insights (break-glass, separate component from the app's; shared workspace) ----------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-net-${prefix}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: 'apim-${prefix}'
  location: location
  tags: tags
  // Developer supports the long-running connections SSE/token streaming needs; Consumption does not.
  sku: enableStreaming ? { name: 'Developer', capacity: 1 } : { name: 'Consumption', capacity: 0 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: 'RAG Chatbot Sample'
  }
}

// APIM gateway logs + metrics -> central workspace (raw platform diagnostics, alongside the App Insights traces).
resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output apimName string = apim.name
output apimPrincipalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
output appInsightsName string = appInsights.name

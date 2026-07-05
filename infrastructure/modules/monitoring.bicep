// rg-monitoring — the observability tier. One central Log Analytics workspace that every other tier
// (networking/APIM, app, ai) points at: App Insights telemetry lands here, and every platform
// resource's diagnostic logs + metrics are routed here too. Single pane of glass, single lifecycle,
// CAF-aligned (the "management" tier owns the platform workspace). The functional modules keep their
// own App Insights components (gateway vs app stay distinct) but share THIS workspace behind them.

import { Tags } from '../types.bicep'

@description('Azure region for the central Log Analytics workspace.')
param location string

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

@description('Workspace data retention in days.')
param retentionInDays int = 30

// The single workspace. PerGB2018 pay-as-you-go; POC ingestion volume is negligible.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${prefix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
  }
}

output workspaceId string = logAnalytics.id
output workspaceName string = logAnalytics.name

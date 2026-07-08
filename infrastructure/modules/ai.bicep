// rg-ai — the model/data-plane tier: Foundry (Azure OpenAI) + AI Search. Both keyless
// (disableLocalAuth). This module also owns the CROSS-RG role assignments whose TARGET lives here:
//   - APIM's MI (born in rg-networking) -> Foundry, so the gateway calls models with no key.
//   - the app's UAMI (born in rg-app)   -> Search, so the app reads/writes indexes with no key.
// A role assignment must be authored at the scope of its target resource, so it lives with the
// resource, not with the principal — this is the seam where the identity graph crosses RG lines.

import { ChatModel, Roles, Tags } from '../types.bicep'

@description('Azure region for Foundry (co-located with the models/gpt-5-mini).')
param location string

@description('Azure region for AI Search. Split out because Search capacity is often exhausted in a given region independently of Foundry — point it at a region that has capacity. Defaults to the Foundry region.')
param searchLocation string = location

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

@description('The app UAMI principalId (from rg-app) — granted Search data/service roles here.')
param appPrincipalId string

@description('The APIM MI principalId (from rg-networking) — granted the Foundry role here.')
param apimPrincipalId string

@description('Built-in role definition GUIDs, keyed by role name.')
param roles Roles

@description('Chat models to deploy — one Foundry deployment per entry (see main.bicep, the single source of truth).')
param chatModels ChatModel[]

@description('Resource ID of the central Log Analytics workspace (from rg-monitoring). Foundry + Search diagnostics flow here.')
param logAnalyticsWorkspaceId string

// ---------- Foundry / Azure OpenAI — public endpoint, keyless from APIM via MI ----------
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'aif-${prefix}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: 'aif-${prefix}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true // no account keys — APIM authenticates with its managed identity
  }
}

// One deployment per picker model (main.bicep's chatModels). @batchSize(1) creates them serially —
// Cognitive Services rejects parallel deployment writes on an account. The deployment name IS the
// model name the app sends as the request body `model`, which is what APIM routes on: add a model in
// main.bicep and it's reachable through the unchanged gateway.
@batchSize(1)
resource chatDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for m in chatModels: {
  parent: foundry
  name: m.name
  sku: { name: 'GlobalStandard', capacity: 10 }
  properties: {
    model: { format: 'OpenAI', name: m.name, version: m.version }
  }
}]

resource embedDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: 'text-embedding-3-large'
  dependsOn: [chatDeployments] // after all chat deployments — deployments create serially
  sku: { name: 'Standard', capacity: 10 }
  properties: {
    model: { format: 'OpenAI', name: 'text-embedding-3-large', version: '1' }
  }
}

// ---------- AI Search — RBAC-only (no admin keys). App reads/writes via its MI ----------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'srch-${prefix}'
  location: searchLocation
  tags: tags
  sku: { name: 'basic' } // RBAC/keyless works on every tier; basic bills ~$0.10/hr (billing stops on delete), avoids the free tier's regional capacity scarcity
  properties: {
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'enabled'
    disableLocalAuth: true // keyless: data-plane auth is Entra-only (supported on free)
  }
}

// ---------- Diagnostics -> central workspace (Foundry request/response + audit, Search query logs) ----------
resource foundryDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: foundry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource searchDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: search
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

// ---------- Cross-RG role assignments (targets live in this RG) ----------

// APIM MI -> Foundry (call Azure OpenAI without a key)
resource raApimFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, apimPrincipalId, roles.cognitiveOpenAiUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cognitiveOpenAiUser)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// App UAMI -> Search (create indexes + read/write docs)
resource raAppSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, appPrincipalId, roles.searchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource raAppSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, appPrincipalId, roles.searchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchIndexDataContributor)
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output foundryEndpoint string = foundry.properties.endpoint
// The search service exposes no endpoint output property, so the URL is constructed from the name.
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchName string = search.name

targetScope = 'subscription'

@description('APIM publisher email (any address you own).')
param publisherEmail string

@description('Location for the resource groups and all resources.')
param location string = deployment().location

@description('Region for AI Search only. Split out because Search capacity is frequently exhausted in a region independently of everything else — override this (e.g. eastus) when the primary region cannot provision Search. Defaults to the primary location.')
param searchLocation string = location

@description('Base name; combined with a subscription-stable hash for globally-unique resource names.')
@minLength(3)
@maxLength(11)
param baseName string = 'ragchat'

@description('Resource group for the edge/gateway tier (APIM, gateway observability).')
param networkingRgName string = 'rg-ragchat-networking'

@description('Resource group for the application tier (container, Postgres, ACR, kv-app, primary observability).')
param appRgName string = 'rg-ragchat-app'

@description('Resource group for the model/data-plane tier (Foundry, AI Search).')
param aiRgName string = 'rg-ragchat-ai'

@description('Resource group for the observability tier (the central Log Analytics workspace every tier logs to).')
param monitoringRgName string = 'rg-ragchat-monitoring'

@description('APIM subscription key the app uses to call the gateway. Defaults to a fresh GUID so it is never a committed value; stored in kv-app and referenced by the Container App. NOTE: newGuid() re-rolls on every deploy, so an unspecified key ROTATES each deployment (APIM + kv-app stay in sync within a deploy). Pass an explicit value to pin it.')
@secure()
param apimSubscriptionKey string = newGuid()

@description('Container image for the app. First deploy uses the public placeholder; after `az acr build` you redeploy with <acr>.azurecr.io/ragchat:<tag>.')
param appImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Container image for the ingestion Job. Placeholder until you `az acr build ./ingestion` and redeploy with <acr>.azurecr.io/ragchat-ingestion:<tag>. The Job is event-triggered by blob drops, so the placeholder is never run (no documents exist until you build + seed).')
param ingestImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

var prefix = '${baseName}${uniqueString(subscription().id, baseName)}'
var tags = { workload: 'rag-chatbot' }

var roles = {
  cognitiveOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' // the Job CONSUMES source docs (read-only)
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // the deployer seeds docs (`make seed`)
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Job: read+delete trigger msgs; KEDA: peek length
  storageQueueDataMessageSender: 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a' // Event Grid: deliver blob events to the queue
}

// ============================================================================
// Resource groups — one per ownership boundary.
// ============================================================================
resource rgNetworking 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: networkingRgName
  location: location
  tags: tags
}

resource rgApp 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: appRgName
  location: location
  tags: tags
}

resource rgAi 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: aiRgName
  location: location
  tags: tags
}

resource rgMonitoring 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: monitoringRgName
  location: location
  tags: tags
}

// ============================================================================
// monitoring — the central Log Analytics workspace. Created first (no deps); every other tier
// consumes its workspace ID, which is also what orders them after this module.
// ============================================================================
module monitoring 'modules/monitoring.bicep' = {
  scope: rgMonitoring
  name: 'monitoring'
  params: {
    location: location
    prefix: prefix
    tags: tags
  }
}

// ============================================================================
// identity — the app UAMI, created first so ai (RBAC) and app (runs-as) both depend on it.
// ============================================================================
module identity 'modules/identity.bicep' = {
  scope: rgApp
  name: 'identity'
  params: {
    location: location
    prefix: prefix
    tags: tags
  }
}

// ============================================================================
// networking — APIM edge + gateway-tier observability.
// ============================================================================
module networking 'modules/networking.bicep' = {
  scope: rgNetworking
  name: 'networking'
  params: {
    location: location
    prefix: prefix
    tags: tags
    publisherEmail: publisherEmail
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ============================================================================
// ai — Foundry + Search + the cross-RG grants whose targets live here.
// ============================================================================
module ai 'modules/ai.bicep' = {
  scope: rgAi
  name: 'ai'
  params: {
    location: location
    searchLocation: searchLocation
    prefix: prefix
    tags: tags
    appPrincipalId: identity.outputs.principalId
    apimPrincipalId: networking.outputs.apimPrincipalId
    roles: roles
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ============================================================================
// apim-ai — the LLM-egress API on the gateway (routing, KV-ref keys, subscription).
// ============================================================================
module apimAi 'modules/apim-ai.bicep' = {
  scope: rgNetworking
  name: 'apim-ai'
  params: {
    apimName: networking.outputs.apimName
    gatewayAppInsightsName: networking.outputs.appInsightsName
    foundryEndpoint: ai.outputs.foundryEndpoint
    apimSubscriptionKey: apimSubscriptionKey
  }
}

// ============================================================================
// app — the container (runs as the UAMI), Postgres, ACR, kv-app, primary observability.
// ============================================================================
module app 'modules/app.bicep' = {
  scope: rgApp
  name: 'app'
  params: {
    location: location
    prefix: prefix
    tags: tags
    tenantId: subscription().tenantId
    uamiId: identity.outputs.id
    uamiPrincipalId: identity.outputs.principalId
    uamiClientId: identity.outputs.clientId
    uamiName: identity.outputs.name
    apimGatewayUrl: networking.outputs.gatewayUrl
    searchEndpoint: ai.outputs.searchEndpoint // implicitly waits for ai (incl. Search RBAC)
    apimSubscriptionKey: apimSubscriptionKey
    appImage: appImage
    ingestImage: ingestImage
    roles: roles
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    monitoringRgName: monitoringRgName
  }
}

// ============================================================================
// apim-app — the north-south ingress API: the SAME gateway fronts the app (served at root so the
// UI's relative fetches route back through APIM). Configured last, once the app FQDN exists.
// ============================================================================
module apimApp 'modules/apim-app.bicep' = {
  scope: rgNetworking
  name: 'apim-app'
  params: {
    apimName: networking.outputs.apimName
    appBackendUrl: 'https://${app.outputs.appFqdn}'
  }
}

// ============================================================================
// Outputs — endpoints and names only. No secret is ever emitted (rule 5). APP_URL is now the APIM
// gateway root: users hit the gateway, which proxies to the app.
// ============================================================================
output APP_URL string = networking.outputs.gatewayUrl
output APP_DIRECT_URL string = 'https://${app.outputs.appFqdn}' // the app's own FQDN (public on Consumption); for debugging
output APIM_BASE_URL string = '${networking.outputs.gatewayUrl}/ai/v1'
output ACR_LOGIN_SERVER string = app.outputs.acrLoginServer
output ACR_NAME string = app.outputs.acrName
output CONTAINER_APP_NAME string = app.outputs.containerAppName
output APP_RESOURCE_GROUP string = appRgName
output SEARCH_ENDPOINT string = ai.outputs.searchEndpoint
output STORAGE_ACCOUNT string = app.outputs.storageAccountName // upload source docs here for ingestion
output BLOB_CONTAINER string = app.outputs.blobContainerName
output INGEST_JOB_NAME string = app.outputs.ingestJobName // `az containerapp job start -n <this>`
output PG_HOST string = app.outputs.pgHost
output PG_DB string = app.outputs.pgDb
output UAMI_NAME string = identity.outputs.name // = the app's Postgres login name (PG_USER)
output KV_APP_NAME string = app.outputs.kvAppName // vault holding the APIM key; `make env` reads it locally
output APP_INSIGHTS_NAME string = app.outputs.appInsightsName
output GATEWAY_APP_INSIGHTS_NAME string = networking.outputs.appInsightsName
output MONITORING_RESOURCE_GROUP string = monitoringRgName
output LOG_ANALYTICS_NAME string = monitoring.outputs.workspaceName

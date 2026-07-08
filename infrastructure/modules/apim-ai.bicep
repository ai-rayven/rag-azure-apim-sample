@description('Name of the existing APIM service to attach the AI-egress API to.')
param apimName string

@description('The gateway-tier (rg-networking) App Insights name — break-glass telemetry, not the app pane.')
param gatewayAppInsightsName string

@description('Foundry endpoint, e.g. https://aif-x.openai.azure.com/ (trailing slash).')
param foundryEndpoint string

@description('The subscription key the app presents to the gateway; also stored in kv-app.')
@secure()
param apimSubscriptionKey string

@description('Token streaming toggle.')
param enableStreaming bool

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = { name: apimName }
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = { name: gatewayAppInsightsName }

// ---------- Tracing bridge: APIM -> App Insights, W3C traceparent correlation ----------
resource logger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials: { connectionString: appInsights.properties.ConnectionString }
  }
}

resource diagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 } // sample: keep everything for the demo
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C' // honours inbound traceparent so app spans == APIM spans
    operationNameFormat: 'Url'
  }
}

// ---------- Backend ----------
resource beFoundry 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'foundry'
  properties: { protocol: 'http', url: '${foundryEndpoint}openai/v1' }
}

// ---------- API + operations (OpenAI-shaped) ----------
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'ai'
  properties: {
    displayName: 'AI Gateway'
    path: 'ai/v1'
    protocols: ['https']
    subscriptionRequired: true // enterprise: per-app subscription key = the quota/governance lever
  }
}

resource opChat 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/chat/completions'
  }
}

resource opEmbed 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'embeddings'
  properties: {
    displayName: 'Embeddings'
    method: 'POST'
    urlTemplate: '/embeddings'
  }
}

// ---------- Routing policy (API-level). MI auth; the body's `model` field picks the model. ----------
var backendPolicy = enableStreaming ? '<forward-request buffer-response="false" />' : '<base />'

var policyTemplate = '''
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="foundry" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
  </inbound>
  <backend>{BACKEND}</backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
'''

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(policyTemplate, '{BACKEND}', backendPolicy)
  }
  dependsOn: [opChat, opEmbed, beFoundry]
}

// ---------- Per-app subscription (the key the Container App presents) ----------
resource subApp 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'rag-app'
  properties: {
    displayName: 'RAG chatbot app'
    scope: '/apis/${api.name}'
    primaryKey: apimSubscriptionKey // same value stored in kv-app; the app references it, never copies
    state: 'active'
  }
}

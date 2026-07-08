@description('Name of the existing APIM service to attach the app-ingress API to.')
param apimName string

@description('The container app origin, e.g. https://ca-x.azurecontainerapps.io — APIM forwards here.')
param appBackendUrl string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = { name: apimName }

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'app-ingress'
  properties: {
    displayName: 'App (UI + API)'
    path: '' // served at the gateway root so the UI's relative fetches route back through APIM
    protocols: ['https']
    serviceUrl: appBackendUrl // plain reverse-proxy: operation path is appended to this backend
    subscriptionRequired: false // browser-facing; real edge auth (Entra/JWT) is the hardening step
  }
}

resource opIndex 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'index'
  properties: {
    displayName: 'UI'
    method: 'GET'
    urlTemplate: '/'
  }
}

resource opStatic 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'static'
  properties: {
    displayName: 'Static assets'
    method: 'GET'
    urlTemplate: '/static/{*path}' // wildcard remainder: any asset under /static
    templateParameters: [
      { name: 'path', type: 'string', required: false }
    ]
  }
}

resource opChat 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Chat'
    method: 'POST'
    urlTemplate: '/chat'
  }
}

resource opModels 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'models'
  properties: {
    displayName: 'Model picker options'
    method: 'GET'
    urlTemplate: '/models' // the UI fetches this on load to populate the model dropdown
  }
}

// No /ingest operation: ingestion is a Container Apps Job (the WRITE path), not an HTTP endpoint on
// the app. The app-ingress API only exposes what the browser calls — the UI, its assets, /chat, /models.

import { Roles, Tags } from '../types.bicep'

@description('Azure region for all application-tier resources.')
param location string

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

@description('App UAMI resource ID — the identity the container runs as.')
param uamiId string

@description('App UAMI principalId (objectId) — used for RBAC, incl. the Cosmos DB data-plane role.')
param uamiPrincipalId string

@description('App UAMI clientId — selects this identity for DefaultAzureCredential.')
param uamiClientId string

@description('APIM gateway root URL (from rg-networking). The app calls the LLM API at <url>/ai/v1.')
param apimGatewayUrl string

@description('AI Search endpoint (from rg-ai).')
param searchEndpoint string

@description('The subscription key the app presents to the gateway; stored in kv-app.')
@secure()
param apimSubscriptionKey string

@description('Container image. Provision uses the public placeholder; `azd deploy` builds + updates it.')
param appImage string

@description('Container image for the ingestion Job. Placeholder until you build ./jobs/ingestion-job; the Job is event-triggered by blob drops, so the placeholder never runs.')
param ingestImage string

@description('Built-in role definition GUIDs, keyed by role name.')
param roles Roles

@description('Token streaming toggle')
param enableStreaming bool

@description('Resource ID of the central Log Analytics workspace (from rg-monitoring). Consuming it as a param is also what orders this module AFTER monitoring.')
param logAnalyticsWorkspaceId string

@description('Resource group that holds the central Log Analytics workspace — used to read its customerId/shared key for the Container Apps env, cross-RG.')
param monitoringRgName string

// ---------- Primary observability (app OTel: gen_ai spans, the app->APIM dependency, etc.) ----------
// The workspace itself lives in rg-monitoring; reference it read-only. `logAnalyticsWorkspaceId`
// (passed above) is what forces monitoring to deploy first, so this existing read is always safe.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'log-${prefix}'
  scope: resourceGroup(monitoringRgName)
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-app-${prefix}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

// ---------- kv-app: the app's one secret (the APIM subscription key), vault-per-consumer ----------
resource kvApp 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kvapp${take(prefix, 18)}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
  }
}

resource secretApimKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kvApp
  name: 'apim-subscription-key'
  properties: { value: apimSubscriptionKey }
}

// ---------- Container Registry — MI pull (AcrPull), admin user off ----------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  // prefix always carries a 13-char uniqueString, so this clears ACR's 5-char minimum; the linter
  // can't prove that statically (uniqueString length isn't modeled), so silence the false positive.
  #disable-next-line BCP334
  name: 'acr${prefix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

// ---------- Storage — the ingestion SOURCE (Blob), keyless: MI only, no account keys ----------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // prefix always carries a 13-char uniqueString (>=16 total), so 'st'+take(...,22) clears the 3-char
  // minimum and stays within 24; the linter can't prove take()'s length statically.
  #disable-next-line BCP334
  name: 'st${take(prefix, 22)}' // storage account names: 3-24 lowercase alphanumeric
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false // <-- no account keys; the ingestion Job reads via its managed identity
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled' // private endpoint is the rg-networking hardening pass
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource docsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'documents' // drop source documents here; the Job ingests everything in it
  properties: { publicAccess: 'None' }
}

// ---------- Blob-drop trigger: BlobCreated -> Event Grid -> Storage queue -> KEDA starts the Job ----
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource triggerQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'ingest-events' // Event Grid delivers here; the Job drains it, KEDA scales on its length
}

// Event Grid system topic over the source storage account.
resource egTopic 'Microsoft.EventGrid/systemTopics@2024-06-01-preview' = {
  name: 'egst-${prefix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' } // delivers to the queue as itself (storage has no account keys)
  properties: {
    source: storage.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

// Only files landing in the `documents` container, delivered to the queue via the topic's identity.
resource egSub 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2024-06-01-preview' = {
  parent: egTopic
  name: 'blob-created-to-queue'
  properties: {
    deliveryWithResourceIdentity: {
      identity: { type: 'SystemAssigned' }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          resourceId: storage.id
          queueName: triggerQueue.name
          queueMessageTimeToLiveInSeconds: 604800 // 7 days
        }
      }
    }
    filter: {
      includedEventTypes: ['Microsoft.Storage.BlobCreated']
      subjectBeginsWith: '/blobServices/default/containers/documents/blobs/'
    }
    eventDeliverySchema: 'EventGridSchema'
  }
  dependsOn: [raEgTopicQueue] // the topic identity must be able to write the queue before events flow
}

// ---------- Cosmos DB (NoSQL) — keyless: local auth disabled, Entra data-plane RBAC only. ----------
// Serverless (pay-per-RU) fits the two tiny collections this sample keeps: chat history and
// ingestion dedup state. The RAG vector store is Azure AI Search, not this account.
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: 'cosmos-${prefix}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true // <-- keyless: account keys are rejected; only Entra tokens + data-plane RBAC
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [ { locationName: location, failoverPriority: 0, isZoneRedundant: false } ]
    capabilities: [ { name: 'EnableServerless' } ] // pay-per-request; no provisioned throughput to size
    publicNetworkAccess: 'Enabled' // private endpoint is the rg-networking hardening pass (as with the others)
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmos
  name: 'ragchat'
  properties: { resource: { id: 'ragchat' } }
}

// Chat history — one document per message, partitioned by session so a turn's history is a
// single-partition query. Provisioned here so the app needs no DDL/migrate step at startup.
resource messagesContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDb
  name: 'messages'
  properties: {
    resource: {
      id: 'messages'
      partitionKey: { paths: ['/session_id'], kind: 'Hash' }
    }
  }
}

// Ingestion dedup state — one document per source doc, partitioned by doc_id (point upserts/deletes).
resource stateContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDb
  name: 'ingest_state'
  properties: {
    resource: {
      id: 'ingest_state'
      partitionKey: { paths: ['/doc_id'], kind: 'Hash' }
    }
  }
}

// Cosmos DB Built-in Data Contributor (read+write, data plane). This is a Cosmos sqlRoleAssignment,
// NOT a Microsoft.Authorization/roleAssignments — control-plane Owner/Contributor on the account grant
// zero data access. With disableLocalAuth on, without this role even the subscription owner can't read
// a document.
var cosmosDataContributor = '00000000-0000-0000-0000-000000000002'

// App/Job UAMI -> Cosmos data plane: the app reads/writes history + dedup state as itself, keyless.
resource raAppCosmos 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, uamiId, cosmosDataContributor)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    principalId: uamiPrincipalId
    scope: cosmos.id
  }
}

// Deployer -> Cosmos data plane: portal access. Data Explorer refuses to browse/query documents
// without a data-plane role (local auth is off), even for the subscription owner — this makes
// "look at + query the data in the portal" work right after `azd up`. principalType omitted so it
// resolves for a user OR a CI service principal (same turnkey pattern as the storage/kv grants).
resource raDeployerCosmos 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, deployer().objectId, cosmosDataContributor)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    principalId: deployer().objectId
    scope: cosmos.id
  }
}

// ---------- Diagnostics -> central workspace (KV audit, Cosmos DB logs, Blob/Queue data-plane logs) ----------
resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: kvApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource cosmosDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: cosmos
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }] // DataPlaneRequests, QueryRuntimeStatistics, etc.
    metrics: [{ category: 'Requests', enabled: true }]
  }
}

// Storage data-plane logs (reads/writes/deletes) live on the blob & queue sub-services, not the
// account — this is where the ingestion pipeline's activity is actually visible.
resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

resource queueDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: queueService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

// ---------- Internal role assignments (targets live in this RG) ----------

// App UAMI -> kv-app (read the APIM subscription key)
resource raAppKvApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kvApp.id, uamiId, roles.keyVaultSecretsUser)
  scope: kvApp
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// App UAMI -> ACR (pull the image)
resource raAppAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uamiId, roles.acrPull)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// App/Job UAMI -> source Storage, READ-ONLY. The Job only consumes documents; it never writes to the
// source. Seeding is a separate act done by a human (`uv run scripts/seed.py`), granted below — so the runtime
// identity stays least-privilege (Storage Blob Data Reader), which is the posture you'd ship.
resource raAppStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uamiId, roles.storageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataReader)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Deployer -> source Storage (write). `uv run scripts/seed.py` uploads the demo docs from your machine as YOUR
// az-login identity; with shared-key access off, that needs a data-plane role (control-plane Owner
// isn't enough). Granting it here keeps the demo turnkey and keyless. deployer() is the principal
// running the deployment; principalType is omitted so it resolves for a user OR a CI service principal.
resource raDeployerStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, deployer().objectId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: deployer().objectId
  }
}

// Deployer -> kv-app (read the APIM subscription key). Lets the local-.env step pull the one secret a local
// run needs into a gitignored .env — keyless, from the same source of truth as everything else. Same
// turnkey-demo rationale as the storage grant above; principalType omitted so it resolves for a user
// OR a CI service principal. The secret is never emitted as a Bicep output (rule 5) — only fetched
// on demand by whoever is already authorized to deploy.
resource raDeployerKvApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kvApp.id, deployer().objectId, roles.keyVaultSecretsUser)
  scope: kvApp
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: deployer().objectId
  }
}

// Job UAMI -> trigger queue (read + delete messages; KEDA also peeks its length to scale the Job).
resource raAppQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uamiId, roles.storageQueueDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageQueueDataContributor)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Event Grid system-topic identity -> trigger queue (deliver blob events; storage has no account keys).
resource raEgTopicQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, egTopic.id, roles.storageQueueDataMessageSender)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageQueueDataMessageSender)
    principalId: egTopic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Env shared by the app and the ingestion Job — both run as the UAMI and reach APIM, Search and
// Cosmos DB the same keyless way. Kept in one place so the two containers never drift apart.
var sharedEnv = [
  { name: 'AZURE_CLIENT_ID', value: uamiClientId } // pick THIS MI for DefaultAzureCredential
  { name: 'APIM_BASE_URL', value: '${apimGatewayUrl}/ai/v1' }
  { name: 'APIM_KEY', secretRef: 'apim-subscription-key' }
  { name: 'SEARCH_ENDPOINT', value: searchEndpoint }
  { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
  { name: 'COSMOS_DB', value: cosmosDb.name }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'EMBED_MODEL', value: 'text-embedding-3-large' }
]

// ---------- Container Apps — the app, running as the UAMI ----------
resource caEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${prefix}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${prefix}'
  location: location
  tags: union(tags, { 'azd-service-name': 'app' }) // azd matches this to the `app` service in azure.yaml
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiId}': {} }
  }
  properties: {
    managedEnvironmentId: caEnv.id
    configuration: {
      // Public ingress: on Consumption APIM cannot VNet-integrate, so it reaches this app over its
      // public FQDN. The private-backend + internal-ingress version is the v2/Premium hardening step.
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        { server: acr.properties.loginServer, identity: uamiId }
      ]
      secrets: [
        {
          name: 'apim-subscription-key'
          keyVaultUrl: '${kvApp.properties.vaultUri}secrets/apim-subscription-key'
          identity: uamiId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: appImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(sharedEnv, [
            { name: 'CHAT_MODEL', value: 'gpt-5-mini' }
            { name: 'ENABLE_STREAMING', value: string(enableStreaming) } // must match the APIM SKU (main.bicep sets both)
            { name: 'OTEL_SERVICE_NAME', value: 'rag-app' } // App Insights cloud role name (read path)
          ])
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
  dependsOn: [raAppKvApp, raAppAcr, raAppCosmos, messagesContainer, secretApimKey]
}

// ---------- Ingestion Job — the WRITE path: pull from Blob, Docling-parse + chunk, embed via APIM,
// push to Search. A separate deployable (its own image) sharing this UAMI (keyless) and the APIM key
// secret, so ingest-time embeddings are audited exactly like chat. EVENT-TRIGGERED: KEDA starts an
// execution while the trigger queue (fed by BlobCreated events) is non-empty. You can still start a
// one-off run manually — `az containerapp job start -n <job>` (a full rescan).
// Docling's models make this image large; 1 vCPU / 2 GiB gives the parse room to run.
// api 2024-10-02-preview: managed-identity auth on job scale rules (the `identity` field below).
resource ingestJob 'Microsoft.App/jobs@2024-10-02-preview' = {
  name: 'caj-${prefix}'
  location: location
  tags: union(tags, { 'azd-service-name': 'ingestion' }) // azd matches this to the `ingestion` service; updated via the Jobs API
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiId}': {} }
  }
  properties: {
    environmentId: caEnv.id
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 1800 // 30 min budget per run
      replicaRetryLimit: 1
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 1 // one full incremental pass at a time; the Job drains the whole queue
          pollingInterval: 30
          rules: [
            {
              name: 'blob-events'
              type: 'azure-queue'
              metadata: {
                accountName: storage.name
                queueName: 'ingest-events'
                queueLength: '1'
              }
              identity: uamiId // KEDA reads the queue length via the managed identity (keyless)
            }
          ]
        }
      }
      registries: [
        { server: acr.properties.loginServer, identity: uamiId }
      ]
      secrets: [
        {
          name: 'apim-subscription-key'
          keyVaultUrl: '${kvApp.properties.vaultUri}secrets/apim-subscription-key'
          identity: uamiId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'ingest'
          image: ingestImage
          resources: { cpu: json('1.0'), memory: '2Gi' } // Docling parse needs the headroom
          env: concat(sharedEnv, [
            { name: 'BLOB_ACCOUNT', value: storage.name }
            { name: 'BLOB_CONTAINER', value: docsContainer.name }
            { name: 'QUEUE_NAME', value: triggerQueue.name }
            { name: 'OTEL_SERVICE_NAME', value: 'rag-ingestion' } // App Insights cloud role name (write path)
          ])
        }
      ]
    }
  }
  dependsOn: [raAppKvApp, raAppAcr, raAppStorage, raAppQueue, raAppCosmos, stateContainer, secretApimKey]
}

output appFqdn string = app.properties.configuration.ingress.fqdn
output containerAppName string = app.name
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output cosmosAccountName string = cosmos.name
output cosmosDbName string = cosmosDb.name
output kvAppName string = kvApp.name
output appInsightsName string = appInsights.name
output storageAccountName string = storage.name
output blobContainerName string = docsContainer.name
output ingestJobName string = ingestJob.name

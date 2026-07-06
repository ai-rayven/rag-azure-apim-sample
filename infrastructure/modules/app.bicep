import { Roles, Tags } from '../types.bicep'

@description('Azure region for all application-tier resources.')
param location string

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

@description('Entra tenant ID (for Key Vault and Postgres Entra auth).')
param tenantId string

@description('App UAMI resource ID — the identity the container runs as.')
param uamiId string

@description('App UAMI principalId (objectId) — used for RBAC and as the Postgres Entra admin.')
param uamiPrincipalId string

@description('App UAMI clientId — selects this identity for DefaultAzureCredential.')
param uamiClientId string

@description('App UAMI name — also the Postgres login name the app connects as.')
param uamiName string

@description('APIM gateway root URL (from rg-networking). The app calls the LLM API at <url>/ai/v1.')
param apimGatewayUrl string

@description('AI Search endpoint (from rg-ai).')
param searchEndpoint string

@description('Azure AI Language endpoint (the multi-service Foundry account, from rg-ai) — the app PII-scrubs trace content here before exporting to App Insights.')
param languageEndpoint string

@description('The subscription key the app presents to the gateway; stored in kv-app.')
@secure()
param apimSubscriptionKey string

@description('Container image. Provision uses the public placeholder; `azd deploy` builds + updates it.')
param appImage string

@description('Container image for the ingestion Job. Placeholder until you build ./ingestion; the Job is event-triggered by blob drops, so the placeholder never runs.')
param ingestImage string

@description('Built-in role definition GUIDs, keyed by role name.')
param roles Roles

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

// ---------- Postgres — Entra-only (no password). The UAMI is the server's Entra admin ----------
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'pg-${prefix}'
  location: location
  tags: tags
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '16'
    storage: { storageSizeGB: 32 }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled' // <-- the password is gone; there is nothing to leak or rotate
      tenantId: tenantId
    }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: 'ragchat'
}

// Let Azure-hosted resources (the Container App) reach Postgres. 0.0.0.0 is the documented
// "allow all Azure services" sentinel — not a public-internet opening.
resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgres
  name: 'allow-azure-services'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// The server's Entra admin IS the app's UAMI — the admin resource's NAME is the principal's objectId.
// Bicep needs a resource name known at deployment start; uamiPrincipalId is a module PARAMETER (not a
// live resource reference), so it qualifies — no separate module needed to launder it.
resource pgAadAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: postgres
  name: uamiPrincipalId
  properties: {
    principalType: 'ServicePrincipal'
    principalName: uamiName // the Postgres login name the app connects as
    tenantId: tenantId
  }
  dependsOn: [pgFwAzure, pgDb] // avoid concurrent server modifications
}

// ---------- Diagnostics -> central workspace (KV audit, Postgres logs, Blob/Queue data-plane logs) ----------
resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: kvApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource pgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: postgres
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
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
// Postgres the same keyless way. Kept in one place so the two containers never drift apart.
var sharedEnv = [
  { name: 'AZURE_CLIENT_ID', value: uamiClientId } // pick THIS MI for DefaultAzureCredential
  { name: 'APIM_BASE_URL', value: '${apimGatewayUrl}/ai/v1' }
  { name: 'APIM_KEY', secretRef: 'apim-subscription-key' }
  { name: 'SEARCH_ENDPOINT', value: searchEndpoint }
  { name: 'PG_HOST', value: postgres.properties.fullyQualifiedDomainName }
  { name: 'PG_USER', value: uamiName }
  { name: 'PG_DB', value: 'ragchat' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'LANGUAGE_ENDPOINT', value: languageEndpoint } // PII-scrub trace content before it reaches App Insights
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
            { name: 'OTEL_SERVICE_NAME', value: 'rag-app' } // App Insights cloud role name (read path)
          ])
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
  dependsOn: [raAppKvApp, raAppAcr, pgAadAdmin, secretApimKey]
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
  dependsOn: [raAppKvApp, raAppAcr, raAppStorage, raAppQueue, pgAadAdmin, secretApimKey]
}

output appFqdn string = app.properties.configuration.ingress.fqdn
output containerAppName string = app.name
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output pgHost string = postgres.properties.fullyQualifiedDomainName
output pgDb string = pgDb.name
output kvAppName string = kvApp.name
output appInsightsName string = appInsights.name
output storageAccountName string = storage.name
output blobContainerName string = docsContainer.name
output ingestJobName string = ingestJob.name

@export()
@description('Built-in Azure role definition GUIDs, keyed by role name. Assembled in main.bicep and threaded to the modules that author role assignments (ai, app).')
type Roles = {
  cognitiveOpenAiUser: string
  keyVaultSecretsUser: string
  searchIndexDataContributor: string
  searchServiceContributor: string
  acrPull: string
  storageBlobDataReader: string
  storageBlobDataContributor: string
  storageQueueDataContributor: string
  storageQueueDataMessageSender: string
}

@export()
@description('Resource tags applied to every resource in the deployment.')
type Tags = {
  workload: string
}

@export()
@description('A chat model offered in the app picker: a Foundry deployment name + pinned version. Single source of truth (main.bicep) threaded to `ai` (creates one deployment per entry) and `app` (derives the CHAT_MODELS env var). The deployment name is what the app sends as the request body `model` — which is exactly what APIM routes on — so adding an entry needs no gateway change, even across providers (all served via the unified /openai/v1 endpoint).')
type ChatModel = {
  name: string
  version: string
  format: string? // deployment model format; defaults to 'OpenAI'. Partner models set their own, e.g. 'Mistral AI'.
  capacity: int? // GlobalStandard capacity; defaults to 10. MaaS partner models (Mistral, etc.) are token-billed and take capacity 1.
}

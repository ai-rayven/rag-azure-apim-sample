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

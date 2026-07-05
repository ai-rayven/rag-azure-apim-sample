import { Tags } from '../types.bicep'

@description('Azure region for the managed identity.')
param location string

@description('Globally-unique naming prefix (baseName + subscription-stable hash).')
param prefix string

@description('Tags applied to every resource.')
param tags Tags

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${prefix}'
  location: location
  tags: tags
}

output id string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
output name string = uami.name

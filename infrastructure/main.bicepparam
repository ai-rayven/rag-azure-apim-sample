using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME')
param location = readEnvironmentVariable('AZURE_LOCATION')
param searchLocation = readEnvironmentVariable('SEARCH_LOCATION', 'eastus')
param publisherEmail = readEnvironmentVariable('APIM_PUBLISHER_EMAIL', 'raiselmartinez@gmail.com')
param enableStreaming = bool(readEnvironmentVariable('ENABLE_STREAMING', 'true'))

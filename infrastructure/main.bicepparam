using './main.bicep'

// azd is the connective tissue: it exports the environment's values (.azure/<env>/.env) into the
// process env at provision time, and these readEnvironmentVariable() calls pull them into bicep.
// Set the non-default ones once per environment, e.g. `azd env set SEARCH_LOCATION eastus`.
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME')
param location = readEnvironmentVariable('AZURE_LOCATION')
param searchLocation = readEnvironmentVariable('SEARCH_LOCATION', 'eastus')
param publisherEmail = readEnvironmentVariable('APIM_PUBLISHER_EMAIL', 'raiselmartinez@gmail.com')

// A single Azure Monitor Workbook over the central Log Analytics workspace — the read-path/ingestion
// "single pane". A consumer of the observability substrate (it reads telemetry every tier emits), so
// main.bicep wires it in LAST, after the tiers it visualises. The dashboard body lives in the sibling
// workbook.json (loaded verbatim) so this module stays small and the volatile KQL never sits next to
// stable resource definitions.

import { Tags } from '../types.bicep'

@description('Azure region for the workbook resource.')
param location string

@description('Tags applied to every resource.')
param tags Tags

@description('Resource ID of the central Log Analytics workspace the workbook queries and is bound to.')
param workspaceId string

// The name must be a GUID; derive it deterministically so redeploys update the SAME workbook in place.
var workbookName = guid(workspaceId, 'rag-observability')

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'RAG-over-APIM — Observability'
    category: 'workbook'
    sourceId: workspaceId // bind to the workspace; the JSON's queries run against it by default
    serializedData: loadTextContent('workbook.json')
  }
}

output workbookId string = workbook.id // full resource ID; build a portal deep link from it (see the WORKBOOK_ID output)

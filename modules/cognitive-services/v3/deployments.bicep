

@description('Configuration array for the model deployments')
param modelsConfig array = []

param cognitiveServiceName string

resource cognitiveService 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: cognitiveServiceName
}

// Only this account's models. Filtering here keeps deployment names unique within the copy loop —
// two accounts can share a deployment name (e.g. a load-balanced pool) without an ARM self-reference.
var accountModels = filter(modelsConfig, model => !empty(model.?aiservice ?? '') && contains(cognitiveServiceName, model.aiservice))

@batchSize(1)
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [for (model, i) in accountModels: {
  name: model.name
  parent: cognitiveService
  sku: {
    name: model.sku
    capacity: model.capacity
  }
  properties: {
    model: {
      format: model.?publisher ?? model.?format
      name: model.?model ?? model.name
      version: model.version
    }
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}]

output modelDeployments array = [for (model, i) in accountModels: {
  name: modelDeployment[i].name
  resourceId: modelDeployment[i].id
  modelName: modelDeployment[i].properties.model.name
  modelVersion: modelDeployment[i].properties.model.version
  modelFormat: modelDeployment[i].properties.model.format
  description: model.?description ?? null
  supportedEndpoints: concat(
    (modelDeployment[i].properties.?capabilities.?chatCompletion ?? 'false') == 'true' ? ['/openai/v1/chat/completions'] : [],
    (modelDeployment[i].properties.?capabilities.?responses ?? 'false') == 'true' ? ['/openai/v1/responses'] : []
  )
  policies: model.?policies ?? []
}]

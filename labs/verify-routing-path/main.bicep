param apimSku string = 'Basicv2'
param aiServicesConfig array
param modelsConfig array
param backendPoolsConfig array
param apimSubscriptionsConfig array = [
  {
    name: 'verify-routing-path'
    displayName: 'Verify routing path'
  }
]

module lawModule '../../modules/operational-insights/v1/workspaces.bicep' = {
  name: 'lawModule'
}

module appInsightsModule '../../modules/monitor/v1/appinsights.bicep' = {
  name: 'appInsightsModule'
  params: {
    lawId: lawModule.outputs.id
    customMetricsOptedInType: 'WithDimensions'
  }
}

module apimModule '../../modules/apim/v2/apim.bicep' = {
  name: 'apimModule'
  params: {
    apimSku: apimSku
    apimSubscriptionsConfig: apimSubscriptionsConfig
    lawId: lawModule.outputs.id
    appInsightsId: appInsightsModule.outputs.id
    appInsightsInstrumentationKey: appInsightsModule.outputs.instrumentationKey
  }
}

module foundryModule '../../modules/cognitive-services/v3/foundry.bicep' = {
  name: 'foundryModule'
  params: {
    aiServicesConfig: aiServicesConfig
    modelsConfig: modelsConfig
    apimPrincipalId: apimModule.outputs.principalId
    foundryProjectName: 'verify-routing-path'
    lawId: lawModule.outputs.id
    appInsightsId: appInsightsModule.outputs.id
    appInsightsInstrumentationKey: appInsightsModule.outputs.instrumentationKey
  }
}

module inferenceAPIModule '../../modules/apim/v3/inference-api.bicep' = {
  name: 'inferenceAPIModule'
  params: {
    policyXml: loadTextContent('policy.xml')
    apimLoggerId: apimModule.outputs.loggerId
    appInsightsId: appInsightsModule.outputs.id
    appInsightsInstrumentationKey: appInsightsModule.outputs.instrumentationKey
    aiServicesConfig: foundryModule.outputs.extendedAIServicesConfig
    inferenceAPIType: 'PassThrough'
    inferenceAPIPath: 'verify-routing-path'
    backendPoolsConfig: backendPoolsConfig
  }
}

output gatewayUrl string = '${apimModule.outputs.gatewayUrl}/verify-routing-path/openai/v1/chat/completions'
output subscriptionKey string = apimModule.outputs.apimSubscriptions[0].key
output applicationInsightsName string = appInsightsModule.outputs.name
output logAnalyticsWorkspaceName string = lawModule.outputs.name
output logAnalyticsWorkspaceId string = lawModule.outputs.customerId

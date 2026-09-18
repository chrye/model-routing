// ------------------
//    PARAMETERS
// ------------------

param aiServicesConfig array = []
param modelsConfig array = []
param apimSku string
param apimSubscriptionsConfig array = []
param inferenceAPIType string = 'AzureOpenAI'
param inferenceAPIPath string = 'inference' // Path to the inference API in the APIM service
param foundryProjectName string = 'default'
param legacyFoundryConfig object = {
  backendName: 'foundry4'
  location: resourceGroup().location
  deploymentName: 'legacy-gpt-4o'
  modelName: 'gpt-4o'
  modelVersion: '2024-11-20'
  modelSku: 'GlobalStandard'
  capacity: 20
}
param foundry5Config object = {
  backendName: 'foundry5'
  location: 'eastus2'
}

@description('Named backend pools grouping backends for priority/weight load balancing (e.g. PTU/TPM spillover).')
param backendPoolsConfig array = []

// ------------------
//    RESOURCES
// ------------------

// 1. Log Analytics Workspace
module lawModule '../../modules/operational-insights/v1/workspaces.bicep' = {
  name: 'lawModule'
}

// 2. Application Insights
module appInsightsModule '../../modules/monitor/v1/appinsights.bicep' = {
  name: 'appInsightsModule'
  params: {
    lawId: lawModule.outputs.id
    customMetricsOptedInType: 'WithDimensions'
  }
}

// 3. API Management
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

// 4. AI Foundry
module foundryModule '../../modules/cognitive-services/v3/foundry.bicep' = {
    name: 'foundryModule'
    params: {
      aiServicesConfig: aiServicesConfig
      modelsConfig: modelsConfig
      apimPrincipalId: apimModule.outputs.principalId
      foundryProjectName: foundryProjectName
      lawId: lawModule.outputs.id
      appInsightsId: appInsightsModule.outputs.id
      appInsightsInstrumentationKey: appInsightsModule.outputs.instrumentationKey
    }
  }

// 5. Legacy hub-based Foundry project with a classic Azure OpenAI account
module legacyHubOpenAIModule 'legacy-hub-openai.bicep' = {
  name: 'legacyHubOpenAIModule'
  params: {
    location: legacyFoundryConfig.location
    backendName: legacyFoundryConfig.backendName
    deploymentName: legacyFoundryConfig.deploymentName
    modelName: legacyFoundryConfig.modelName
    modelVersion: legacyFoundryConfig.modelVersion
    modelSku: legacyFoundryConfig.modelSku
    modelCapacity: legacyFoundryConfig.capacity
    applicationInsightsId: appInsightsModule.outputs.id
    apimPrincipalId: apimModule.outputs.principalId
  }
}

// 6. New Foundry 5 project connected to classic Azure OpenAI (foundry4) via AOAI Connector
module foundry5Module 'foundry5-connected-openai.bicep' = {
  name: 'foundry5Module'
  params: {
    location: foundry5Config.location
    backendName: foundry5Config.backendName
    foundryProjectName: foundryProjectName
    targetOpenAIAccountId: legacyHubOpenAIModule.outputs.openAIAccountId
    targetOpenAIEndpoint: legacyHubOpenAIModule.outputs.backendConfig.endpoint
    apimPrincipalId: apimModule.outputs.principalId
  }
}

var inferenceBackends = concat(
  foundryModule.outputs.extendedAIServicesConfig,
  [
    legacyHubOpenAIModule.outputs.backendConfig
    foundry5Module.outputs.backendConfig
  ]
)

// 7. APIM Inference API
module inferenceAPIModule '../../modules/apim/v3/inference-api.bicep' = {
  name: 'inferenceAPIModule'
  params: {
    policyXml: loadTextContent('policy.xml')
    apimLoggerId: apimModule.outputs.loggerId
    appInsightsId: appInsightsModule.outputs.id
    appInsightsInstrumentationKey: appInsightsModule.outputs.instrumentationKey
    aiServicesConfig: inferenceBackends
    inferenceAPIType: inferenceAPIType
    inferenceAPIPath: inferenceAPIPath
    backendPoolsConfig: backendPoolsConfig
  }
}


// ------------------
//    OUTPUTS
// ------------------

output logAnalyticsWorkspaceId string = lawModule.outputs.customerId
output apimServiceId string = apimModule.outputs.id
output apimResourceGatewayURL string = apimModule.outputs.gatewayUrl

output apimSubscriptions array = apimModule.outputs.apimSubscriptions
output legacyFoundryHubId string = legacyHubOpenAIModule.outputs.hubId
output legacyFoundryProjectId string = legacyHubOpenAIModule.outputs.projectId
output legacyOpenAIAccountId string = legacyHubOpenAIModule.outputs.openAIAccountId
output foundry5AccountId string = foundry5Module.outputs.accountId
output foundry5ProjectId string = foundry5Module.outputs.projectId
output foundry5ProjectEndpoint string = foundry5Module.outputs.projectEndpoint

@description('Azure region for the legacy hub-based Foundry resources and Azure OpenAI account.')
param location string

@description('Logical APIM backend name for the classic Azure OpenAI endpoint.')
param backendName string = 'foundry4'

@description('Name of the classic Azure OpenAI deployment.')
param deploymentName string = 'legacy-gpt-4o'

@description('Classic Azure OpenAI model name.')
param modelName string = 'gpt-4o'

@description('Classic Azure OpenAI model version.')
param modelVersion string = '2024-11-20'

@description('Classic Azure OpenAI deployment SKU.')
param modelSku string = 'GlobalStandard'

@description('Classic Azure OpenAI deployment capacity in thousands of tokens per minute.')
param modelCapacity int = 20

@description('Resource ID of the Application Insights instance used by the legacy hub.')
param applicationInsightsId string

@description('Managed identity principal ID of API Management.')
param apimPrincipalId string

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)
var cognitiveServicesOpenAIUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'legacyai${resourceSuffix}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'legacy-ai-${resourceSuffix}'
  location: location
  properties: {
    accessPolicies: []
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
  }
}

resource openAIAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${backendName}-${resourceSuffix}'
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    apiProperties: {
      statisticsEnabled: false
    }
    customSubDomainName: toLower('${backendName}-${resourceSuffix}')
    // Local auth is disabled to comply with policies that block listKeys; APIM and the hub connection use Entra ID.
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource openAIDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  name: deploymentName
  parent: openAIAccount
  sku: {
    name: modelSku
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

resource hub 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: 'legacy-aihub-${resourceSuffix}'
  location: location
  kind: 'Hub'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    applicationInsights: applicationInsightsId
    description: 'Legacy hub-based Microsoft Foundry resource for classic Azure OpenAI'
    friendlyName: 'Legacy AI Hub'
    hbiWorkspace: false
    keyVault: keyVault.id
    storageAccount: storageAccount.id
  }
}

resource project 'Microsoft.MachineLearningServices/workspaces@2024-07-01-preview' = {
  name: 'legacy-project-${resourceSuffix}'
  location: location
  kind: 'Project'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    description: 'Legacy hub-based Foundry project containing the classic Azure OpenAI connection'
    friendlyName: 'Legacy AOAI Project'
    hbiWorkspace: false
    hubResourceId: hub.id
  }
}

resource openAIConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-04-01-preview' = {
  name: 'legacy-azure-openai'
  parent: hub
  properties: {
    authType: 'AAD'
    category: 'AzureOpenAI'
    isSharedToAll: true
    metadata: {
      ApiType: 'azure'
      ApiVersion: '2025-03-01-preview'
      ResourceId: openAIAccount.id
    }
    target: openAIAccount.properties.endpoint
  }
}

resource apimOpenAIUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAIAccount.id, apimPrincipalId, cognitiveServicesOpenAIUserRoleDefinitionId)
  scope: openAIAccount
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleDefinitionId
  }
}

output backendConfig object = {
  name: backendName
  location: location
  endpoint: openAIAccount.properties.endpoint
  deploymentName: openAIDeployment.name
  modelName: modelName
  modelVersion: modelVersion
}

output hubId string = hub.id
output projectId string = project.id
output openAIAccountId string = openAIAccount.id
output openAIEndpoint string = openAIAccount.properties.endpoint

@description('Azure region for the new Foundry 5 resource.')
param location string

@description('Logical APIM backend name for the Foundry 5 endpoint.')
param backendName string = 'foundry5'

@description('AI Foundry project name prefix.')
param foundryProjectName string = 'default'

@description('Target classic Azure OpenAI account resource ID (foundry4).')
param targetOpenAIAccountId string

@description('Target classic Azure OpenAI account endpoint URL.')
param targetOpenAIEndpoint string

@description('Managed identity principal ID of API Management.')
param apimPrincipalId string

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)
var cognitiveServicesUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)
var cognitiveServicesOpenAIUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)
var aiProjectManagerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'eadc314b-1a2d-4efa-be10-5d325db5065e'
)

// Reference the target classic AOAI account for role assignment
resource targetOpenAIAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(targetOpenAIAccountId, '/'))
}

// 1. New AI Foundry Account (kind: AIServices)
resource foundry5Account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: '${backendName}-${resourceSuffix}'
  location: location
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: toLower('${backendName}-${resourceSuffix}')
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

// 2. Child Project under Foundry 5
resource foundry5Project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  #disable-next-line BCP334
  name: '${foundryProjectName}-${backendName}'
  parent: foundry5Account
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// 3. AzureOpenAI Connection connecting Foundry 5 Project to Foundry 4 Classic AOAI
resource openAIConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  name: 'aoai-connector-foundry4'
  parent: foundry5Project
  properties: {
    category: 'AzureOpenAI'
    target: targetOpenAIEndpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: targetOpenAIAccountId
      location: location
    }
  }
}

// 4. Role assignment: Grant Deployer AI Project Manager role on Foundry 5
resource deployerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry5Account.id, deployer().objectId, aiProjectManagerRoleDefinitionId)
  scope: foundry5Account
  properties: {
    principalId: deployer().objectId
    principalType: 'User'
    roleDefinitionId: aiProjectManagerRoleDefinitionId
  }
}

// 5. Role assignment: Grant APIM Cognitive Services User role on Foundry 5
resource apimUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry5Account.id, apimPrincipalId, cognitiveServicesUserRoleDefinitionId)
  scope: foundry5Account
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesUserRoleDefinitionId
  }
}

// 6. Role assignment: Grant Foundry 5's identity Cognitive Services OpenAI User role on Foundry 4
resource foundry5ToFoundry4Role 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetOpenAIAccount.id, foundry5Account.id, cognitiveServicesOpenAIUserRoleDefinitionId)
  scope: targetOpenAIAccount
  properties: {
    principalId: foundry5Account.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleDefinitionId
  }
}

output backendConfig object = {
  name: backendName
  location: location
  endpoint: foundry5Account.properties.endpoint
}

output accountId string = foundry5Account.id
output accountName string = foundry5Account.name
output projectId string = foundry5Project.id
output projectName string = foundry5Project.name
output projectEndpoint string = 'https://${foundry5Account.name}.services.ai.azure.com/api/projects/${foundry5Project.name}'
output connectionName string = openAIConnection.name

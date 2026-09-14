# Based only on current Microsoft Learn documentation, the accurate terminology is:  

```text
Azure subscription  
└── Resource group  
    └── Microsoft Foundry resource 
        ├── Foundry project  
        │   ├── Agents, tools, files, evaluations, connections, etc.  
        │   └── Project endpoint  
        │  
        ├── Model deployment  
        │   ├── Deployment name  
        │   ├── Model name  
        │   ├── Model version  
        │   ├── Deployment option/type and SKU  
        │   └── Content filter and capacity configuration  
        │  
        └── Resource-level inference endpoints  
```

## 1. Azure subscription  

The Azure subscription is the billing, quota, policy, and access boundary above the Foundry resource.  
A subscription contains one or more resource groups.  

## 2. Resource group  

The resource group is the Azure Resource Manager container holding the Foundry resource and potentially related resources:  
```text
Resource group
├── Microsoft Foundry resource
├── API Management
├── Key Vault
├── Storage
└── Other supporting resources
```

This is standard Azure resource organization, not a Foundry-only layer.  

## 3. Microsoft Foundry resource  

The current official term is: __Microsoft Foundry resource__

You may still encounter terms such as:  
- Foundry account  
- Azure AI Foundry resource  
- AI Services resource  
- Foundry account/resource  

For current architecture discussions, I would say Foundry resource, not simply "Foundry account," unless describing a specific Azure resource type or API property.  

The Foundry resource is the parent Azure resource that provides access to models, agents, tools, credentials, and service endpoints. Microsoft explicitly says that a Foundry resource provides unified access to models, agents, and tools. Microsoft Foundry SDKs and endpoints.  

Foundry resource: contoso-foundry  
Region: West US 2  

The following are two __supported inference surfaces__ over the same Microsoft Foundry resource, optimized for different use cases.
#### 1. Foundry project endpoint
Use the following endpoint to call all your deployed base models (Microsoft Foundry project endpoint root):
```
https://contoso-foundry.services.ai.azure.com/api/projects/<your_project_name>
```

For the Responses API, the complete runtime URL is:

```
POST https://contoso-foundry.services.ai.azure.com/api/projects/<your_project_name>/openai/v1/responses
```

The request selects a deployment using the __model__ field:
```json
{
   "model": "my-gpt-deployment",
   "input": "Summarize this document."
}
```
#### 2. Azure OpenAI-compatible resource endpoint
This remains valid for supported deployments:
```
https://contoso-foundry.openai.azure.com/openai/v1/  
```

For Responses API:
```
POST https://contoso-foundry.openai.azure.com/openai/v1/responses
```

Using the same deployment selection pattern:
```JSON
{
   "model": "my-gpt-deployment",
   "input": "Summarize this document."
}
```
__NOTE__: In OLDER deployment-based Azure OpenAI API, Chat Completions URL looks like this:
```
POST https://<azure-openai-resource-name>.openai.azure.com/openai/deployments/<deployment-name>/chat/completions?api-version=<api-version>

Example:  
POST https://contoso-aoai.openai.azure.com/openai/deployments/legacy-gpt-4o/chat/completions?api-version=2024-10-21
```

## 4. Foundry project  

A Foundry project is created under or managed by the Foundry resource.  

Microsoft describes the project as organizing the models, agents, and other resources used by the team. Quickstart: Set up Microsoft Foundry resources  

```text
Foundry resource: contoso-foundry
└── Project: audit-ai-prod
```

The project is primarily an application-development, collaboration, governance, and isolation boundary for items such as:  

Agents  
Connections to external resources  
Evaluations  
Files and tools  
Project configuration  
Project-specific access control  
Project endpoint  

The project has a project-scoped endpoint:  

https://<foundry-resource>.services.ai.azure.com/api/projects/<project-name>  


Example:  

https://contoso-foundry.services.ai.azure.com/api/projects/audit-ai-prod  


That endpoint is used by the Foundry SDK and project-scoped APIs. Microsoft distinguishes it from the OpenAI inference endpoint. Microsoft Foundry SDKs and endpoints  

## 5. Connected resource or connection  

This is the key layer missing from your list, especially for the customer scenario.  

```text
Foundry project
└── Connection
    └── Existing Azure OpenAI resource
```

A connection is project or resource configuration that allows Foundry experiences to authenticate to another service or resource, such as:  

Existing Azure OpenAI resource  
Azure AI Search  
Storage  
Cosmos DB  
Content Safety  
External or gateway-based model endpoint  

For your customer, the terminology should be:  
```text
New Foundry resource
└── New Foundry project
    └── Azure OpenAI connection
        └── Existing Azure OpenAI resource
            └── legacy-gpt-4o deployment
```

Do not say that the connection "moves the model into the new Foundry project." It references the separately existing Azure OpenAI resource.  

## 6. Model  

The model is the underlying model offering and version, for example:  

Model family/name: gpt-4o  
Model version: 2024-05-13  


A model in the catalog is not necessarily callable until it is deployed. Microsoft states that deploying a model makes it available for inference, although instant access is now documented as a preview exception for certain supported models. Deployment overview for Microsoft Foundry Models  

The model name and deployment name are different concepts.  

## 7. Model deployment  

A model deployment is the configured instance or alias through which an application accesses a model.  

Example:  

Deployment name: legacy-gpt-4o  
Model name: gpt-4o  
Model version: 2024-05-13  


Microsoft describes deployments as aliases for model access. A deployment defines the model name, model version, provisioning or capacity type, content filtering, and rate-limiting configuration. Endpoints for Microsoft Foundry Models  

One model can potentially have several deployments:  
```text
Model: gpt-4o
├── Deployment: gpt-4o-dev
├── Deployment: gpt-4o-prod
└── Deployment: legacy-gpt-4o
```

These could differ in version, capacity, deployment type, content filter, and intended workload.  

## 8. Deployment name  

The deployment name is the caller-facing alias for a model deployment.  

legacy-gpt-4o  


With the OpenAI v1 API, the caller usually supplies the deployment name in the model field:  

{  
  "model": "legacy-gpt-4o",  
  "input": "Summarize this document."  
}  


Despite the field being named model, for deployed Azure OpenAI or Foundry models, its value is normally the deployment name, not necessarily the underlying catalog model name. Microsoft states that the deployment name is passed in the model field for /openai/v1/ requests. Endpoints for Microsoft Foundry Models  

For example:  

Underlying model name: gpt-4o  
Deployment name: audit-production-primary  
Request:  
"model": "audit-production-primary"  

## 9. Deployment option, deployment type, and SKU  

A deployment has an operational or capacity configuration. Current Foundry documentation distinguishes deployment options such as:  

- __Serverless API__ — used by Azure OpenAI and other Foundry Models sold by Azure.  
- __Managed compute__ — used for open-source and custom models on dedicated compute; some scenarios are in preview.  

Within Serverless API, deployment types include categories such as:  

Standard  
Provisioned  
Batch  
Developer  

These can have regional, data-zone, or global processing characteristics. Deployment overview for Microsoft Foundry Models. Deployment types for Microsoft Foundry Models.  

The deployment type has a corresponding __SKU code__ used in ARM, Bicep, and Azure Policy:  

| Deployment type | SKU code |
| --- | --- |
| Global Standard | `GlobalStandard` |
| Global Provisioned | `GlobalProvisionedManaged` |
| Global Batch | `GlobalBatch` |
| Data Zone Standard | `DataZoneStandard` |
| Data Zone Provisioned | `DataZoneProvisionedManaged` |
| Data Zone Batch | `DataZoneBatch` |
| Standard | `Standard` |
| Regional Provisioned | `ProvisionedManaged` |
| Developer | `DeveloperTier` |

For Azure OpenAI scenarios, terminology can include:  

Deployment option: Serverless API  
Deployment type: Global Standard  
SKU code: `GlobalStandard`  
Model: gpt-4o  
Model version: ...  
Deployment name: audit-gpt-4o-prod  

Do not call Global Standard or Provisioned the "model type." It is the deployment type.  

## 10. Endpoints  

“Endpoint” is not one single hierarchy layer. A Foundry resource can expose several endpoints for different purposes.  

A. OpenAI v1 model-inference endpoint  
```
https://<foundry-resource>.openai.azure.com/openai/v1/  
```
For Responses API:  
```
POST https://<foundry-resource>.openai.azure.com/openai/v1/responses  
```

The request supplies the deployment name in _model._ Endpoints for Microsoft Foundry Models  

This endpoint is resource-based, not project-name-based.  

B. Foundry project endpoint  
```
https://<foundry-resource>.services.ai.azure.com/api/projects/<project-name>  
```

This endpoint includes the project name and is used for Foundry project APIs and project-scoped capabilities. Microsoft Foundry SDKs and endpoints  

C. Other service or protocol endpoints  

A Foundry resource may expose additional protocol-specific or tool-specific endpoints, for example an Anthropic-compatible endpoint or endpoints for individual Foundry Tools. Microsoft documents that endpoint choice depends on the SDK and capability being used. 



I would describe the customer configuration this way:  

The customer has a new Microsoft Foundry resource in West US 2. Under that resource, they created a Foundry project. The project has an Azure OpenAI connection referencing an existing Azure OpenAI resource that was previously used by a hub-based project. That existing Azure OpenAI resource contains the legacy-gpt-4o model deployment. The deployment uses GPT-4o as the underlying model. The application reaches the model through an inference endpoint, potentially through APIM.  

Expanded:  
```text
Azure subscription
└── Resource group
    ├── New Microsoft Foundry resource, West US 2
    │   ├── Foundry project
    │   │   └── Azure OpenAI connection
    │   │       └── Existing Azure OpenAI resource
    │   │           └── Model deployment: legacy-gpt-4o
    │   │               ├── Model name: gpt-4o
    │   │               ├── Model version
    │   │               ├── Deployment type/SKU
    │   │               ├── Capacity/quota
    │   │               └── Content filter configuration
    │   └── Project endpoint
    │
    └── API Management
        └── Backend route to the applicable inference endpoint
```
## Recommended vocabulary table  

| Term | Recommended meaning |
| --- | --- |
| Microsoft Foundry | The overall product/platform |
| Foundry resource | Parent Azure resource hosting unified Foundry capabilities |
| Foundry project | Project-scoped organization and application-development boundary |
| Connection | Reference and authentication configuration for another resource or service |
| Azure OpenAI resource | Existing or new Azure resource containing Azure OpenAI deployments |
| Model | Underlying catalog model, such as GPT-4o |
| Model version | Specific version of that model |
| Model deployment | Configured deployment of a model |
| Deployment name | Alias used by the application to select the deployment |
| Deployment option/type/SKU | Hosting, processing, and commercial/capacity configuration |
| Inference endpoint | Runtime API used to invoke models |
| Project endpoint | API endpoint used for project-scoped Foundry capabilities |
| APIM endpoint | Customer-facing gateway endpoint, if APIM fronts the Foundry or Azure OpenAI data plane |

## Bottom line  

Correct Interpretation:  
```text
Subscription
  -> Resource group
    -> Foundry resource
      -> Foundry project
        -> Project assets and connections

Foundry resource or connected Azure OpenAI resource
  -> Model deployment
    -> Deployment name
    -> Underlying model name and version
    -> Deployment type/SKU
    -> Capacity and content-filter configuration

Runtime access
  -> Project endpoint or resource-level inference endpoint
  -> API operation, such as /openai/v1/responses
  -> Deployment selected using the request's model field
```


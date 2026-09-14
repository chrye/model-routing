
In the current Microsoft Foundry (unified resource) model, **model deployments are resource-scoped, not project-scoped.**


## Why deployments sit on the Foundry resource

1. **The inference endpoint is resource-scoped.**
   The OpenAI-compatible endpoint is:
   ```
   https://<foundry-resource>.openai.azure.com/openai/v1/
   ```
   There is no project name in that URL. The `model` field in the request resolves the deployment name **against the resource**, not against a project. If deployments lived under a project, the URL would have to include the project — it doesn't.

2. **Deployments are an ARM child of the account (Foundry/AI Services resource).**
   In Bicep/ARM, the resource type is `Microsoft.CognitiveServices/accounts/deployments` — a direct child of the *account* (the Foundry resource). There is no `.../projects/{project}/deployments/...` resource path. Quota and capacity are also tracked on the account.

3. **Projects consume deployments; they don't own them.**
   A Foundry project is an application/collaboration/governance boundary. It holds agents, connections, evaluations, files, tools, and RBAC scoping — but it references the resource's deployments (or references *external* deployments via a **connection**, e.g. an existing Azure OpenAI resource). **<span style="color: red;">Multiple projects under the same Foundry resource share the same deployment pool.</span>**

4. **The project endpoint is a different surface.**
   ```
   https://<foundry-resource>.services.ai.azure.com/api/projects/<project-name>/openai/v1/responses
   ```
   This project endpoint routes through the project (for agents, project-scoped auth, connections, etc.), but the deployment it ultimately targets is still the one provisioned on the Foundry resource (or on a connected AOAI resource).

## Where the confusion often comes from

- **Hub-based AI Foundry (older Azure AI Studio model)** had *hubs* and *projects*, and it was common to think of deployments as being "in the project." Even then, they were technically on the connected AOAI/AI Services resource, not the project itself.
- **Connections** make a deployment *usable from* a project — that's a discovery/auth relationship, not ownership.

## So the tree stays:

```text
Microsoft Foundry resource
├── Foundry project           ← agents, tools, connections, evaluations, project endpoint
└── Model deployment          ← deployment name, model, version, SKU, content filter, quota
```


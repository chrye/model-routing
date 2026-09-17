# How the Azure OpenAI connector translates requests (classic/hub AOAI via APIM)

> **Scope:** an Azure OpenAI *connector* pointing at an older/classic Azure OpenAI account that was attached
> to a hub, with inference calls arriving through **APIM**. Both API surfaces are covered — **Chat
> Completions** and the **Responses API** — because a recurring finding here is that the two are
> interchangeable for this deployment, and choosing APIM does not force you onto either one.

---

## Short version

A **connector** (also called a *connection*) is a saved note that says *"this other Azure resource exists,
here is its address, and here is how to authenticate to it."*

It is a **bookmark, not a bridge**. Adding one does not make another account's models callable through yours.

So the question *"how does the connector translate my request?"* has a blunt answer:

> **It doesn't translate anything. It never sees your request.**

The work everyone attributes to the connector is actually done by two other things: **APIM** (picks the
backend, swaps the credential) and the **classic Azure OpenAI account itself** (finds the model).

| Name | What it is | Role here |
|---|---|---|
| `foundry4` | The **classic** Azure OpenAI account, once attached to a hub | Actually owns the `legacy-gpt-4o` deployment |
| `foundry5` | A **new** Foundry resource with **no models of its own** | Holds the connector pointing at `foundry4` |
| APIM | API Management gateway | The real router and credential swapper |
| `legacy-gpt-4o` | A deployment (gpt-4o, 2024-11-20) | The model everyone is trying to reach |

### Four terms used throughout

- **Control plane** — managing resources: creating them, listing them, reading their settings. Connectors
  live here.
- **Data plane** — actually calling the model to get an answer. Connectors are absent here.
- **API surface** — the *shape* of the request: Chat Completions (`/openai/deployments/{d}/chat/completions`)
  vs. Responses (`/openai/responses`). They carry the model name in different places.
- **Endpoint** — the *hostname* you call. One Foundry resource exposes more than one, and — as this document
  proves — they do not accept the same auth token.

Those last two are independent axes. Keeping them apart is most of the battle.

---

## The headline: the connector translates nothing

A `category: AzureOpenAI` connection stores three things: a **target URL**, an ARM **`ResourceId`**, and an
**auth mode**. That is all. It is not a reverse proxy, not a router, and not a URL rewriter.

The lab already says this correctly in [README.md](README.md#L57): *"AOAI connector to foundry4
(control-plane discovery only, no model)."*

The governing rule is simple: **a model name is looked up on the resource whose hostname you called.** A name
that doesn't match a deployment on *that* resource is a documented **404**. No Microsoft Learn page documents
cross-account inference forwarding over a connection.

So both of these **fail** — verified, not assumed:

```http
POST https://foundry5-xxxx.openai.azure.com/openai/v1/responses
{ "model": "legacy-gpt-4o" }     →  404, deployment not on foundry5
```

```http
POST https://foundry5-xxxx.services.ai.azure.com/api/projects/<p>/openai/v1/responses
{ "model": "legacy-gpt-4o" }     →  404  (with a correctly-scoped ai.azure.com token)
```

`foundry5` has no deployments at all ([foundry5-connected-openai.bicep](foundry5-connected-openai.bicep)).
Adding the connection did not import `legacy-gpt-4o` into its namespace — on either endpoint.

### How this was proven

Every scenario below was run against a live deployment, and **every result matched the prediction**. Each
endpoint gets a matched pair: the connected deployment name, and a control name that exists nowhere.

*(Numbering continues from the six direct-vs-APIM scenarios listed in the appendix.)*

| # | Endpoint | `model` | Token audience | Observed |
|---|---|---|---|---|
| 7 | **resource** | `legacy-gpt-4o` | `cognitiveservices` | **404** ✅ |
| 8 | **resource** | *<span style="color: red;">Control Case</span>* `deployment-that-does-not-exist` | `cognitiveservices` | **404** ✅ identical to 7 |
| 9 | **project** | `legacy-gpt-4o` | `cognitiveservices` | **401** ✅ wrong audience for this endpoint |
| 10 | **project** | `legacy-gpt-4o` | `ai.azure.com` | **404** ✅ auth passed, lookup still failed |
| 11 | **project** | *<span style="color: red;">Control Case</span>* `deployment-that-does-not-exist` | `ai.azure.com` | **404** ✅ identical to 10 |
| — | control plane | `az cognitiveservices account deployment list` on `foundry5` | — | `[]`, while the connection object exists |

**The controls turn this from anecdote into proof.** A lone 404 could be a typo, a propagation delay, or a
malformed request. But `legacy-gpt-4o` and a name that was never created *anywhere* return the **same status
on the same endpoint** — 7≡8, and 10≡11. The connected deployment is therefore indistinguishable from one
that does not exist. It holds no privileged position in `foundry5`'s namespace.

**Scenario 10 answered a question Microsoft has not documented.** No published page states whether the
project endpoint can reach deployments on a *connected* account. The observed **404** settles it: **it
cannot.**

The 9→10 pair is what makes that conclusive. Had scenario 10 also failed on auth, *"I was blocked"* would be
indistinguishable from *"the model isn't there."* Because 10 authenticated **successfully** and still
returned 404, the failure is unambiguously model lookup — not access.

---

## What actually translates the request

Two components do real work; the connector is not one of them.

### Hop 1 — Client → APIM

The notebook uses the `AzureOpenAI` client with a dated api-version, not the v1 client:

```python
inference_api_type = "PassThrough"
inference_api_version = "2025-03-01-preview"
client = AzureOpenAI(azure_endpoint=f"{gateway}/inference", api_key=..., api_version=...)
```

> **Which API surface does this lab actually use for `legacy-gpt-4o`?** **Chat Completions**, not Responses.
> [model-routing.ipynb](model-routing.ipynb#L343) states it outright: *"The legacy `gpt-4o` compatibility
> route is exercised through Chat Completions above."* The Chat Completions loop includes `legacy-gpt-4o`;
> the Responses loop deliberately omits it.

So the actual on-wire request is the deployment-scoped form — against the **APIM host**, not the AOAI host:

```http
POST https://apim-xxxx.azure-api.net/inference/openai/deployments/legacy-gpt-4o/chat/completions?api-version=2025-03-01-preview
api-key: <APIM subscription key>

{ "model": "legacy-gpt-4o", "messages": [ { "role": "user", "content": "which model are you using?" } ] }
```

The deployment name appears in **both the path and the body** — the SDK *copies* it, it does not *move* it.
That is precisely what lets the body-`model` router work for Chat Completions.

The same deployment is equally reachable through Responses via the same gateway:

```http
POST https://apim-xxxx.azure-api.net/inference/openai/responses?api-version=2025-03-01-preview
api-key: <APIM subscription key>

{ "model": "legacy-gpt-4o", "input": "which model are you using?" }
```

For Responses the deployment name is carried by the **body `model` field only** — there is no
`/deployments/{id}/` path segment, and no such route exists (see *Host vs. API surface* below).

### Hop 2 — APIM policy resolution

The APIM API is imported from a **wildcard** `/*` passthrough spec
([PassThrough.json](../../modules/apim/v3/specs/PassThrough.json)), which declares no named template
parameters. Therefore `context.Request.MatchedParameters["deployment-id"]` can **never** be populated — for
either API surface. The first branch of [policy.xml](policy.xml#L6) is effectively dead code in this lab, and
`requestedModel` **always** falls through to the body `model`:

- `deployment` → empty (no route param)
- `model` → `legacy-gpt-4o` (parsed from `reqBody` with `preserveContent: true`)
- `requestedModel` → `legacy-gpt-4o`

It then hits the legacy branch at [policy.xml](policy.xml#L53):

```xml
<when condition="...== &quot;legacy-gpt-4o&quot;">
  <set-backend-service backend-id="foundry4" />
</when>
```

Crucially, `legacy-gpt-4o` is matched **before** the `gpt-4o*` gate below it, which is why the legacy
deployment survives while every other `gpt-4o` variant gets a 403. Order matters here — move the gate above
it and the legacy route dies.

In the `<backend>` section, `legacy-gpt-4o` falls into `<otherwise>` → plain `<forward-request />`.
**No `rewrite-uri`, no `set-body`.** Contrast with the `gpt-5-mini` branch, which is the only place in this
lab where genuine translation happens (path *and* body rewriting for PTU→TPM spillover).

### Hop 3 — APIM → classic account

With `inferenceAPIType = 'PassThrough'`, `endpointPath` is empty, so the backend URL in
[inference-api.bicep](../../modules/apim/v3/inference-api.bicep#L124) is the bare account root and the
wildcard spec appends the remaining path verbatim:

```http
POST https://foundry4-xxxx.openai.azure.com/openai/deployments/legacy-gpt-4o/chat/completions?api-version=2025-03-01-preview
Authorization: Bearer <token for https://cognitiveservices.azure.com>

{ "model": "legacy-gpt-4o", "messages": [ ... ] }
```

(For a Responses call the same rules apply, yielding
`POST https://foundry4-xxxx.openai.azure.com/openai/responses?api-version=2025-03-01-preview`.)

The **only** things that changed across the gateway are the host, the path prefix (`/inference` stripped),
and the credential. Body untouched, `model` untouched, path untouched, api-version untouched.

### Hop 4 — the classic account resolves it locally

The classic account looks up `legacy-gpt-4o` among **its own** deployments — from the path for Chat
Completions, from body `model` for Responses — and routes to gpt-4o `2024-11-20`.

**End-to-end chain:**

```
model field (body) ──APIM policy reads it──▶ backend selection
                  └──forwarded verbatim────▶ classic account's local deployment lookup
```

The connector appears nowhere in that chain.

---

## Auth: the one real "translation"

This is the substantive conversion, and it's done by APIM, not the connector.

| Leg | Credential |
|---|---|
| Client → APIM | `api-key: <APIM subscription key>` (APIM's own key, unrelated to AOAI) |
| APIM → classic account | `Authorization: Bearer <Entra token>`, minted from APIM's managed identity via the backend's `credentials.managedIdentity.resource` |

APIM swaps an APIM subscription key for an Entra bearer token. That swap is **mandatory** here: the classic
account sets `disableLocalAuth: true` ([legacy-hub-openai.bicep](legacy-hub-openai.bicep#L77)), so key auth
is dead and every path to it must be Entra-based. The RBAC that makes it work is the
`Cognitive Services OpenAI User` assignment to the APIM principal at
[legacy-hub-openai.bicep](legacy-hub-openai.bicep#L157).

⚠️ **`Cognitive Services Contributor` cannot make inference calls with Entra ID**, despite the name sounding
more powerful. `Cognitive Services OpenAI User` (`5e0bd9bd-…`) is the correct minimum — which is what the
Bicep uses.

⚠️ **`disableLocalAuth: true` does not force traffic through APIM.** It disables *key* auth only. Any
principal holding `Cognitive Services OpenAI User` can still call the classic account directly with an Entra
token, bypassing the gateway entirely — which scenarios 3 and 4 demonstrate. A hard guarantee needs network
controls plus RBAC scoped to the APIM identity alone.

### The Entra audience depends on the *endpoint*

Microsoft's own documentation is inconsistent here: current Learn samples use
`https://ai.azure.com/.default`, while APIM backend docs still show `https://cognitiveservices.azure.com`.
**Testing shows both are correct — they describe different endpoints:**

| Endpoint (hostname) | Required audience | Wrong audience yields |
|---|---|---|
| `*.openai.azure.com` (resource) | `https://cognitiveservices.azure.com/.default` | — |
| `*.services.ai.azure.com/api/projects/<p>` (project) | `https://ai.azure.com/.default` | **401** |

The same token, against the same Foundry account, reaches deployment resolution on the resource endpoint
(**404**) but is rejected outright on the project endpoint (**401**). A 401 means the token was never
accepted; a 403 would mean the identity was recognized but unauthorized.

**The audience is a property of the endpoint you call, not of the resource that owns it.** That is why the
APIM backend in this lab works with `cognitiveservices.azure.com` — it targets `*.openai.azure.com`. Anything
calling a project endpoint needs the other audience.

### `api-key` is two different credentials

The single most confusing thing in this topology is that the header `api-key` appears on both sides of the
gateway carrying **unrelated** credentials:

| Where | `api-key` contains | Validated by |
|---|---|---|
| Client → classic AOAI (direct) | Azure OpenAI **account key** | AOAI data plane — rejected, local auth off |
| Client → APIM | **APIM subscription key** | APIM gateway — accepted |

Same header name, different issuers, different validators. On a wildcard passthrough the client's `api-key`
is also forwarded to the backend unless a policy strips it, so this collision is worth keeping in mind when
debugging unexplained 401s.

### Observed: `disableLocalAuth` returns **403**, not the documented 401

Microsoft's [disable-local-auth](https://learn.microsoft.com/azure/ai-services/disable-local-auth) guidance
(current as of 2026-09) says to verify the setting by looking for **401**
`Access denied due to invalid subscription key or wrong API endpoint`. In practice this lab observes **403**.

The 403 is the *stronger* signal, and here is why: 401 is also the documented response for an **invalid key
value**. If the gateway had validated a placeholder key and found it wrong, the result would be 401. A 403
means it never compared the value at all — it recognized the credential *type* and refused the *method*.
That is textbook 403 semantics (recognized but forbidden), and it matches how Azure Storage documents the
identical "Shared Key disallowed" case.

Every other possible 403 cause is credential-independent and would also have hit the no-credential scenario,
which returns 401:

| Candidate | Ruled out because |
|---|---|
| Network ACLs / private endpoint | Evaluated before credentials; `publicNetworkAccess: 'Enabled'` and no `networkAcls` declared |
| Azure Policy / deny assignment | Control-plane only; never in the `*.openai.azure.com` data path |
| Content filtering | Runs after auth; surfaces as **400** `content_filter` |
| Missing custom subdomain | Present; and its absence causes 401 on the Entra path |

One caveat before treating this as settled: the placeholder key was never a *valid* key, so strictly the
403 proves the method was refused without proving which rule refused it. The decisive test closes that gap —
temporarily set `disableLocalAuth: false`, wait for propagation, resend the same placeholder key, and confirm
the response flips **403 → 401**.

There is no documented error code (`AuthenticationTypeDisabled`, `LocalAuthDisabled`) for this case.
**Treat the 403 as observed-but-undocumented** — and note that Microsoft's published verification procedure
would report a false negative on this account.

---

## So what *is* the connector doing, in the hub scenario?

There are actually **two** connections in this lab, and they're different resource types:

| | Hub-era connection | Modern connector |
|---|---|---|
| Type | `MachineLearningServices/workspaces/connections` | `CognitiveServices/accounts/projects/connections` |
| Parent | the Hub | the foundry5 project |
| File | [legacy-hub-openai.bicep](legacy-hub-openai.bicep#L139) | [foundry5-connected-openai.bicep](foundry5-connected-openai.bicep#L70) |

Both are `category: AzureOpenAI`, `authType: AAD`, and both point `target` at the same classic endpoint.
Both do the same class of job — all of it **control plane**:

- Listing the model in the portal / playground under "Connected resources"
- SDK enumeration (`.connections.get()` / `.list()`)
- Agent Service and evaluation model binding
- Prompt flow LLM-node wiring (hub-era)
- Credential resolution — under `authType: AAD` there is no stored secret; the connection hands back the
  target address and says "use your own Entra token"

The pattern is: **look up the address and credential, then dial the target yourself.** Network traffic
originates from the *caller*, never from Foundry acting as a middleman.

The hub connection also carries `metadata.ApiVersion: '2025-03-01-preview'`. That is a *hint to
connection-aware clients* about which API generation to use when they build their own calls — it is not
applied to anything transiting APIM.

---

## Host vs. API surface: two independent choices

A common conflation is to assume that fronting the account with APIM also requires abandoning Chat
Completions for Responses. It does not. These are orthogonal:

| Dimension | Options | Guidance |
|---|---|---|
| **Where** (host) | classic AOAI hostname vs. APIM gateway hostname | Use **APIM**, to retain token metrics, routing, model gating, and credential termination |
| **Which** (API surface) | `/openai/deployments/{d}/chat/completions?api-version=` vs. `/openai/responses?api-version=` or `/openai/v1/responses` | **Either** — choose per workload |

Verified points:

- **Deployment-scoped Chat Completions is not deprecated.** No Learn page announces retirement of the
  surface. Microsoft *recommends* Responses for agentic workloads; a recommendation is not a deprecation.
  Retirement in Azure OpenAI is per **model version**, not per API.
- **There is no deployment-scoped Responses route.** `/openai/deployments/{d}/responses` does not exist on
  any host. Confirmed in the `openai-python` source: `/chat/completions` is in the deployment-path
  allowlist, `/responses` is deliberately excluded.
- **gpt-4o `2024-11-20` supports both surfaces**, and is on the documented Responses supported-model list.
  The Responses surface is not restricted by account `kind` — the prerequisites explicitly admit "a Foundry
  resource **or** Azure OpenAI resource."

---

## Consequences you should design around

1. **Connector ≠ gateway coverage.** If a Foundry-hosted feature (agent run, evaluation) ever calls the
   classic account over the connection, that traffic leaves Microsoft's service network and goes straight to
   `foundry4-xxxx.openai.azure.com`. It **bypasses APIM entirely** — no token limits, no
   `azure-openai-emit-token-metric`, no `x-ms-region` visibility, no `policy.xml` routing. The documented fix
   is the dedicated **Azure APIM** / **Model Gateway** connection categories, not an `AzureOpenAI`
   connection.

2. **Responses is stateful; the routing is not.** With `store=true` (default, 30-day retention) a follow-up
   carrying `previous_response_id` is bound to the account that stored it. The `legacy-gpt-4o` route is
   single-backend so it's safe today — but the `gpt-5.4-mini` pool and the `gpt-5-mini` retry path are not
   session-affine. If the legacy route is ever multi-backended, continuation breaks.

3. **Don't inject `api-version` onto v1 paths.** If the client migrates to `/openai/v1/responses`, the route
   uses implicit versioning. The current dated form is the legacy preview surface — it works, but v1 is the
   strategic one.

4. **Hub-project model limits are a red herring here.** The documented "hub-based projects are limited to
   gpt-4o, gpt-4o-mini, gpt-4, gpt-35-turbo" constrains what a *hub project* can consume. It does not
   constrain direct data-plane calls to the AOAI account through APIM.

5. **If `legacy-gpt-4o` must be addressable on foundry5**, the connector will not get you there. Either
   create a deployment of that name on foundry5, or keep the APIM route — which is what this lab already
   does correctly.

---

## Appendix — how this was verified

Two cells in [model-routing.ipynb](model-routing.ipynb) exercise every claim in this document.

**Cell A — direct vs. APIM, against the classic account:**

| # | Host | API surface | Credential | Result |
|---|---|---|---|---|
| 1 | classic AOAI | Chat Completions | none | **401** — no identity established |
| 2 | classic AOAI | Chat Completions | AOAI **account key** | **403** — key auth disabled (docs say 401) |
| 3 | classic AOAI | Chat Completions | Entra bearer | **200** with `Cognitive Services OpenAI User`, else 401/403 |
| 4 | classic AOAI | Responses | Entra bearer | as 3 |
| 5 | APIM gateway | Chat Completions | APIM subscription key | **200** |
| 6 | APIM gateway | Responses | APIM subscription key | **200** |

**Cell B — does the connector proxy?** Scenarios 7–11 plus the control-plane checks, tabulated earlier.

Each cell prints the literal URL, credential type, expected vs. actual status, `x-ms-region`, and — on
failure — `x-ms-error-code`, `WWW-Authenticate` and the error body. `WWW-Authenticate` is worth watching:
RFC 9110 requires it on a genuine 401 challenge and it should be absent on a 403 policy refusal, so a
difference between scenarios 1 and 2 would independently corroborate that the gateway classified them as
two different kinds of rejection.

### Still open

- **The 403 on disabled local auth is undocumented.** Worth reporting to Microsoft, since the published
  verification procedure produces a false negative on this account.
- **Server-side Foundry egress is unmapped.** If an agent run or evaluation calls the classic account over
  the connection, no documentation specifies the outbound request shape or the identity used. Diagnostics on
  the classic account would reveal it: a request with no matching APIM record is Foundry-originated.

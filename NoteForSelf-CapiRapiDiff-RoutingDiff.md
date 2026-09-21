# Note for self — Chat Completions vs. Responses API, and where routing actually happens

Working notes from a Copilot session about `model-routing.ipynb`. Four questions, in order:

1. How are Chat Completions calls different from Responses API calls, beyond the SDK method name?
2. The `azure_endpoint` is identical in both notebook cells — so what does "deployment in the path" mean?
3. Is all the routing happening in APIM, or does Foundry do part of it?
4. Can these conclusions be cross-checked against other models?


---

## 1. Chat Completions vs. Responses — what actually differs on the wire

The SDK surface (`client.chat.completions.create` vs `client.responses.create`) is the least interesting difference.

### 1.1 URL shape — and why it breaks model-based routing

**Chat Completions** puts the deployment in the **path**:

```
POST {endpoint}/openai/deployments/{deployment}/chat/completions?api-version=2025-03-01-preview
```

**Responses** has **no per-deployment route**. The deployment lives **only in the JSON body**:

```
POST {endpoint}/openai/responses?api-version=2025-03-01-preview
POST {endpoint}/openai/v1/responses                      # v1 surface, no api-version
```

`/openai/deployments/{d}/responses` does not exist.

**Consequences for APIM:**

| | Chat Completions | Responses |
|---|---|---|
| Where to read the model | URL template param, free | Must **buffer and parse the body** |
| Policy cost | none | `context.Request.Body.As<JObject>(preserveContent: true)` per request |
| `preserveContent: true` | optional | **mandatory** — else body is consumed and backend gets nothing |
| Rewriting target | `set-backend-service` + keep path | `set-backend-service` + possibly rewrite body `model` |

In this lab that last row is load-bearing. Scenario 1 has deployments named `gpt-5-mini-ptu` / `gpt-5-mini-tpm`, but callers ask for `gpt-5-mini`. Chat Completions rewrites a **path segment**; Responses must rewrite the **body `model`** and re-serialize. Two policy code paths, same logical rule.

Scenario 2 (`gpt-5.4-mini` on `foundry6`/`foundry7`) is easier — deployment name is identical on both backends, so only the backend changes, body untouched.

### 1.2 Input schema

Chat Completions — `messages`, always role-tagged objects:

```json
{ "model": "gpt-4.1",
  "messages": [{"role": "user", "content": "which model are you using?"}] }
```

Responses — `input`, polymorphic:

```json
{ "model": "gpt-4.1", "input": "which model are you using?" }
```

or the rich form:

```json
{ "model": "gpt-4.1",
  "input": [{"role": "user",
             "content": [{"type": "input_text", "text": "..."},
                         {"type": "input_image", "image_url": "..."}]}] }
```

Content-part type names differ: Chat Completions uses `text` / `image_url`; Responses uses `input_text` / `input_image` / `input_file`, and emits `output_text`. A schema-validation policy written for one will reject the other.

Renames:

| Chat Completions | Responses |
|---|---|
| `messages` | `input` |
| system/developer msg inside `messages` | `instructions` (top-level) |
| `max_tokens` / `max_completion_tokens` | `max_output_tokens` |
| `tools[].function.{name,parameters}` (nested) | `tools[].{type,name,parameters}` (flat) |
| `response_format` | `text.format` |
| `n` (multiple choices) | **not supported** |

### 1.3 Output schema — fixed slots vs. flat item list

Chat Completions:

```json
{ "id": "chatcmpl-…", "object": "chat.completion", "model": "gpt-4.1",
  "choices": [{ "index": 0, "finish_reason": "stop",
                "message": {"role": "assistant", "content": "…"} }],
  "usage": {"prompt_tokens": 12, "completion_tokens": 20, "total_tokens": 32} }
```

Responses — ordered, **heterogeneous** `output` array:

```json
{ "id": "resp_…", "object": "response", "status": "completed", "model": "gpt-4.1",
  "output": [
    {"type": "reasoning", "id": "rs_…", "summary": []},
    {"type": "function_call", "name": "get_weather", "call_id": "call_…", "arguments": "{}"},
    {"type": "message", "role": "assistant",
     "content": [{"type": "output_text", "text": "…", "annotations": []}]}
  ],
  "usage": {"input_tokens": 12, "output_tokens": 20, "total_tokens": 32,
            "output_tokens_details": {"reasoning_tokens": 8}} }
```

This is exactly why the notebook's `scenario()` helper branches:

```python
if "choices" in data:   # Chat Completions
    text = data["choices"][0]["message"]["content"]
else:                   # Responses
    text = " ".join(c.get("text","") for item in data.get("output", [])
                    for c in item.get("content", []) if c.get("type") == "output_text")
```

`output_text` in the SDK is a **client-side convenience property** doing that concatenation — not a server field.

### 1.4 Token accounting — different field names

| Chat Completions | Responses |
|---|---|
| `usage.prompt_tokens` | `usage.input_tokens` |
| `usage.completion_tokens` | `usage.output_tokens` |
| `usage.total_tokens` | `usage.total_tokens` |
| `usage.completion_tokens_details.reasoning_tokens` | `usage.output_tokens_details.reasoning_tokens` |

APIM's `azure-openai-emit-token-metric` / `llm-emit-token-metric` normalize these, which is why the notebook's KQL still shows `PromptTokens`/`CompletionTokens` for both. But **custom** policies reaching into `usage.prompt_tokens` will silently emit `0` for Responses traffic. Same risk for `azure-openai-token-limit` — which directly affects whether Scenario 1's spillover trips at all when driven over Responses.

### 1.5 Server-side state — the conceptual break

Chat Completions is **strictly stateless**. Resend full history every turn.

Responses is **optionally stateful**:

- Persisted server-side by default (`store: true`)
- Continue with `previous_response_id` instead of resending history
- `GET` / `DELETE /openai/responses/{id}`, `GET /openai/responses/{id}/input_items`
- `store: false` for zero retention

**Hard constraint on load balancing.** A `previous_response_id` resolves only on the **resource that created it**:

- **Scenario 1** — both deployments on **`foundry2`**, same account → stateful follow-ups survive spillover.
- **Scenario 2** — `foundry6` → `foundry7` are **different accounts** → if the circuit breaker trips between turns, `previous_response_id` 404s.

Safe patterns: `store: false` + full history, or session affinity pinning, or accept single-backend stateful chains.

### 1.6 Streaming

Chat Completions streams `chat.completion.chunk` with `choices[0].delta.content`; terminate on `data: [DONE]`.

Responses streams **typed, named SSE events**:

```
event: response.created
event: response.output_item.added
event: response.content_part.added
event: response.output_text.delta          ← { "delta": "Hel" }
event: response.output_text.done
event: response.function_call_arguments.delta
event: response.completed                  ← full final object, incl. usage
```

Responses' terminal `response.completed` carries full usage. Chat Completions needs `stream_options: {"include_usage": true}` to get usage while streaming at all.

### 1.7 Tools — hosted vs. client-executed

Chat Completions tools are **always client-executed**: model emits `tool_calls` → you run it → append `role: "tool"` message → call again.

Responses adds **hosted tools the service runs itself**: `web_search`, `file_search`, `code_interpreter`, `computer_use`, `image_generation`, and **MCP** servers (`type: "mcp"`).

Tool-result round trip differs too: Chat Completions appends `{"role":"tool","tool_call_id":…}`; Responses appends `{"type":"function_call_output","call_id":…,"output":"…"}` to `input`.

For a gateway: hosted tools mean **the backend makes outbound network calls you don't see** — egress/firewall/exfiltration implications Chat Completions doesn't have.

### 1.8 Reasoning models

Reasoning tokens are **discarded between turns** on Chat Completions — the model re-derives its chain of thought each call. On Responses they're persisted and carried via `previous_response_id`, improving accuracy and reducing billed reasoning tokens on multi-turn work.

Responses-only knobs:

```json
{ "reasoning": { "effort": "high", "summary": "auto" } }
```

Some models are Responses-only; some older/third-party models are Chat-Completions-only. **Routing tables must encode capability, not just name.**

### 1.9 Sampling-parameter compatibility

Reasoning models reject `temperature`, `top_p`, `presence_penalty`, `frequency_penalty`, `logprobs`. A policy unconditionally injecting `"temperature": 0.7` will 400 — most likely on Responses, since that's where reasoning models live. `n` has no Responses equivalent.

### 1.10 Background mode

Responses supports `"background": true` → returns `status: "queued"`, poll `GET /openai/responses/{id}`. With `stream: true` you can reattach and resume from a `sequence_number`.

Chat Completions has no async mode — long jobs hold the socket, so APIM backend/`forward-request` timeout tuning matters much more there.

### 1.11 Error surface and diagnosability

Chat Completions 404s on **path resolution** — the URL itself is invalid.
Responses 404s on **body-field resolution** — the URL is valid; failure is deeper.

That is precisely what scenarios 7–11 exploit: `legacy-gpt-4o` and `deployment-that-does-not-exist` hit the *same URL*, so they form a clean controlled pair. Not constructible as cleanly with Chat Completions, where the two requests would differ in the URL and you'd be testing path routing instead.

### 1.12 Independence from auth/hosting

Surface choice and gateway choice are **orthogonal**. Scenarios 3/4 (direct + Entra) and 5/6 (APIM + subscription key) show both surfaces under both topologies. `disableLocalAuth: true` affects credentials, not API shape.

### 1.13 Summary table

| Dimension | Chat Completions | Responses |
|---|---|---|
| Deployment location | URL path on classic `?api-version=` surface; body-only on `/openai/v1/` (see §2) | Body `model` only, on every surface |
| APIM routing | path-based, cheap | body parse required |
| Input field | `messages` | `input` (+ `instructions`) |
| Output field | `choices[].message.content` | `output[]` heterogeneous array |
| Token fields | `prompt_`/`completion_tokens` | `input_`/`output_tokens` |
| State | stateless always | `store` + `previous_response_id` |
| Streaming | untyped `delta` chunks | typed SSE events |
| Hosted tools | none | web/file search, code interp., MCP, computer use |
| Reasoning carry-forward | discarded | persisted |
| Background mode | no | yes |
| Multiple completions (`n`) | yes | no |
| Direction | maintained, not extended | receives all new capabilities |

**One line:** Chat Completions is a stateless, path-addressed, fixed-shape RPC. Responses is an optionally-stateful, body-addressed, item-stream resource with a lifecycle.

---

## 2. "Same `azure_endpoint`" — resolving the confusion

Both notebook cells pass:

```python
azure_endpoint = f"{apim_resource_gateway_url}/{inference_api_path}"
# e.g. https://apim-xxxx.azure-api.net/inference
```

That is only the **origin + base path**. The `AzureOpenAI` client constructs a **different full URL per method**.

### What each SDK call emits

```python
client.chat.completions.create(model='gpt-4.1', messages=[...])
```
→
```
POST https://apim-xxxx.azure-api.net/inference/openai/deployments/gpt-4.1/chat/completions?api-version=2025-03-01-preview
{"messages":[{"role":"user","content":"which model are you using?"}]}
```

`gpt-4.1` — passed as `model=` — has been **lifted out of the body into the URL path** by the Azure flavor of the SDK.

```python
client.responses.create(model='gpt-4.1', input='...')
```
→
```
POST https://apim-xxxx.azure-api.net/inference/openai/responses?api-version=2025-03-01-preview
{"model":"gpt-4.1","input":"which model are you using?"}
```

`model` **stays in the body**. No deployment segment in the path.

### Side by side

| | Chat Completions | Responses |
|---|---|---|
| `azure_endpoint` (you supply) | `…/inference` | `…/inference` — **identical** |
| Path the SDK appends | `/openai/deployments/{model}/chat/completions` | `/openai/responses` |
| Where `model=` ends up | **URL path segment** | **body `model` field** |
| Body | `{"messages": […]}` | `{"model": "…", "input": "…"}` |

Same base, different route templates. Same Python kwarg, **serialized to a different place on the wire**.

### Why the SDK does this — and the version-surface caveat

Traced directly in `openai-python` source (`src/openai/lib/azure.py`): the SDK keeps a `_deployments_endpoints` set (`/chat/completions`, `/completions`, `/embeddings`, …) that **explicitly excludes `/responses`**. When the call target is in that set and the request body has a `model` key, the SDK rewrites the path to insert `/deployments/{model}`; for `/responses` it never does this, so `model` stays in the body.

"Deployment in the path" is a property of the **classic `api-version=` surface**, not an inherent property of Chat Completions. On the newer `/openai/v1/` GA base URL, Chat Completions **also** becomes non-deployment-scoped:

```
POST {endpoint}/openai/v1/chat/completions      # model stays in body, no /deployments/ segment
```

So the real rule is: **Responses is always body-addressed, on every surface; Chat Completions is body-addressed only on `/openai/v1/`, and path-addressed on the classic `?api-version=` surface.** Check the exact `base_url` / `api_version` in code before assuming path-based routing works for a given Chat Completions call.

### Proof already in the notebook

The raw-`requests` cell writes the URLs literally, no SDK involved:

```python
# Chat Completions — deployment IS in the path
f"{apim_base}/openai/deployments/{deployment}/chat/completions?api-version={inference_api_version}"
chat_body = {"model": deployment, "messages": [...]}

# Responses — no deployment segment; only the body carries it
f"{apim_base}/openai/responses?api-version={inference_api_version}"
resp_body = {"model": deployment, "input": question}
```

### Why it matters for policy

- Chat Completions: read from URL — `@(context.Request.Url.Path)` or a path-template variable. Free.
- Responses: URL is identical for every model. Must parse the body:

```xml
<set-variable name="requestedModel"
  value="@(context.Request.Body.As<JObject>(preserveContent: true)["model"]?.ToString())" />
```

`preserveContent: true` is mandatory or the backend receives an empty body.

---

## 3. Where routing actually happens

**Accurate:** the choice of which Foundry **resource/account** receives the request is made entirely in APIM.
**Not quite accurate:** "all routing happens in APIM" — there are two hand-offs after APIM.

### 3.1 What APIM decides

1. **Which backend/account** — from `model` (path or body) via `set-backend-service`, or a **backend pool** whose member APIM selects.
2. **Which deployment name to request** — e.g. rewriting `gpt-5-mini` → `gpt-5-mini-ptu`.
3. **Retry / failover** — `<retry>` on 429/5xx and circuit-breaker state on `foundry6`/`foundry7` are APIM-side. Foundry never knows a retry happened.
4. **Credential swap** — drops the subscription key, attaches the managed-identity token.

| Scenario | Failover mechanism | Where decided |
|---|---|---|
| 1 — `gpt-5-mini-ptu` → `gpt-5-mini-tpm` | policy retries with a **different deployment name** on the **same account** (`foundry2`) | **APIM** |
| 2 — `foundry6` → `foundry7` | **backend pool** priority + circuit breaker, same deployment name | **APIM** |

Scenario 1 is subtle: APIM changes the *deployment*, not the backend. `foundry2` sees two unrelated requests and 429s the first — it does not fail over. APIM does.

### 3.2 What Foundry decides (after APIM)

**a) Deployment-name → model resolution.** APIM sends a name; the account looks it up in **its own** deployment table, 404s if absent. A lookup, not routing — but it's the step scenarios 7–11 isolate. APIM cannot know whether a name exists on a backend.

**b) Regional placement under `GlobalStandard`.** Every model in `models_config` uses `"sku": "GlobalStandard"`, which explicitly means Azure may serve inference from a **different region than the account's**:

```
you → APIM  →  foundry1 (swedencentral, GlobalStandard)
                     ↓  Azure's own global scheduler
               actual compute: possibly another region
```

APIM chose the *account*. Azure chose *where it ran*. Invisible to APIM. This is exactly why the notebook prints:

```python
print("x-ms-region: ", responses.headers.get("x-ms-region"))
```

If it always matched the selected backend, the header would be redundant.

### 3.3 Mental model

```
┌─ APIM ─────────────────────────────────┐
│ reads model  →  picks ACCOUNT           │  ← your policy, your config
│                 picks DEPLOYMENT NAME   │
│                 retries / breaks circuit│
└────────────────┬───────────────────────┘
                 │ one HTTP request, one target
┌────────────────▼───────────────────────┐
│ Foundry account                         │
│   resolves deployment name (or 404)     │  ← account-local lookup
│   GlobalStandard: Azure picks region    │  ← opaque to you and APIM
└─────────────────────────────────────────┘
```

**Foundry never load-balances *between* accounts here.** `foundry6` does not forward to `foundry7`. `foundry2` does not spill `-ptu` into `-tpm`. No mesh, no cross-account awareness. Scenarios 7–11 prove this negatively: even an explicit `AzureOpenAI` *connection* from `foundry5` to `foundry4` does not make `foundry4`'s deployment reachable on `foundry5`.

### 3.4 Quota is per-resource — GlobalStandard doesn't change that

`GlobalStandard` gives region flexibility *within* one resource's capacity pool; it does not give cross-resource failover. If a resource's own TPM quota is exhausted, Azure will not silently reroute the request to a different resource — that 429 is real and must be handled by APIM (retry/failover to another backend), exactly as Scenario 1/2 do. Quota is enforced per deployment, per resource, per region; multi-resource fan-out via APIM is still the only way to aggregate TPM across accounts.

**Precise framing:** APIM load-balances *across resources*. Foundry load-balances *within the capacity pool behind one resource* (GlobalStandard region choice only). Neither substitutes for the other.

### 3.5 Precise restatement

> **All routing you configured happens in APIM.** APIM alone selects the Foundry account and deployment name, and owns all retry/failover/circuit-breaker behavior. Foundry performs only an account-local deployment-name lookup — plus, under `GlobalStandard`, an Azure-internal choice of serving region that neither you nor APIM control or observe, except via `x-ms-region`.

Operationally: unexpected region → determine whether it's APIM backend selection (your policy) or `GlobalStandard` placement (not your policy). `Standard` / `DataZoneStandard` removes the second variable if you need regional determinism.

---

## 4. Cross-model verification — done

Verified in-session by dispatching background research agents with explicit model overrides — GPT-5.6 Sol (did not complete in time, dropped), Gemini 3.8 Flash, and Claude Opus 5 — each independently answering all four questions, then cross-referenced against the Microsoft Learn pages fetched directly in the same session.

**Result: strong convergence, one genuine refinement, no contradictions.**

- Gemini 3.8 Flash and Claude Opus 5 independently reproduced the §1 findings (URL shapes, schema renames, output structure, usage fields, statefulness/affinity hazard, streaming event model, hosted tools, reasoning persistence) and the §3 findings (APIM = macro-routing/account+deployment selection/retry/failover; Foundry = account-local lookup + opaque `GlobalStandard` region placement) with no material disagreement.
- Claude Opus 5 additionally verified §2 directly against the `openai-python` SDK source (`src/openai/lib/azure.py`) and surfaced the version-surface caveat now folded into §2 above: "deployment in path" is a property of the classic `api-version=` surface, not of Chat Completions per se.
- Direct fetches of Microsoft Learn (`deployment-types`, `responses` how-to, `api-management/backends`) independently confirmed the GlobalStandard region-opacity claim ("may be processed in any Azure region") and the APIM backend-pool/circuit-breaker mechanics.

**Residual caveats, flagged by the models as unverified rather than doc-confirmed** — worth testing empirically against this lab rather than trusting as given:

- Whether APIM's `azure-openai-*` / `llm-*` policies fully recognize `/responses` routes for token counting and streaming.
- Exact error code returned on a cross-resource `previous_response_id` miss (assumed 404-class; not directly reproduced here).
- Responses' regional availability list changes frequently — reverify before assuming every backend in an APIM pool can serve it.

Empirical verification against the live lab (see recipes below) remains the strongest check; cross-model agreement is a fast way to catch a wrong assumption before spending lab time on it.

---

## Verification recipes

| Claim | How to falsify |
|---|---|
| CC puts deployment in path; Responses in body | `os.environ["OPENAI_LOG"] = "debug"` is already set — compare the `Request options: {'url': …}` lines from both cells |
| APIM alone selects the backend | Compare `x-ms-region` against each account's configured `location`; check `ApiManagementGatewayLlmLog`'s `DeploymentName` for `-ptu` vs `-tpm` |
| Usage field names differ | Dump raw JSON before `.parse()` |
| Responses returns heterogeneous `output[]` | Same dump, on a reasoning model — look for a `reasoning` item |
| `GlobalStandard` can serve from another region | Run the loop repeatedly; watch whether `x-ms-region` varies for a fixed model |

Capture raw payloads:

```python
for model in ['gpt-4.1', 'gpt-5-mini', 'gpt-5-nano', 'gpt-5-pro', 'gpt-5.4-mini', 'gpt-5.6-terra']:
    responses = client.responses.with_raw_response.create(model=model, input=input_message)
    print("x-ms-region: ", responses.headers.get("x-ms-region"))
    print("RAW:", responses.text[:1200])   # inspect usage.* names and output[] item types
    output = responses.parse()
    print(f"Model: {output.model} 💬: {output.output_text}\n")
```

### Authoritative sources

- Responses API + lifecycle — `learn.microsoft.com/azure/ai-foundry/openai/how-to/responses` (redirects to `azure/foundry/openai/how-to/responses`)
- Deployment types (GlobalStandard region processing) — `learn.microsoft.com/azure/ai-foundry/openai/how-to/deployment-types` (redirects to `azure/foundry/foundry-models/concepts/deployment-types`)
- APIM backends / pools / circuit breaker — `learn.microsoft.com/azure/api-management/backends`
- `openai-python` SDK source — `src/openai/lib/azure.py` (`_deployments_endpoints`, `_build_request`, `_prepare_url`) — primary evidence for §2's path-construction behavior
- disableLocalAuth — `learn.microsoft.com/azure/ai-services/disable-local-auth`

---

## Confidence levels

**High — doc-verified and cross-model confirmed (Gemini 3.8 Flash, Claude Opus 5, plus direct Microsoft Learn fetches):**
URL shapes, schema field names, `output[]` structure, usage field renames, where routing decisions are made, APIM-vs-Foundry responsibility split, GlobalStandard region opacity, the version-surface dependency of "deployment in path" (§2).

**Lower / version-dependent:**
Exact hosted-tool list, streaming event names, and anything specific to the model versions in `models_config` (`gpt-5.6-terra` @ `2026-07-09`, `gpt-5.4-mini` @ `2026-03-17`, `gpt-5-pro` @ `2025-10-06`). In particular, **"`gpt-5-pro` is Responses-API-only" came from this notebook's own markdown**, not from independent knowledge — treat it as the lab author's assertion, not verified fact. APIM's exact policy-level handling of `/responses` routes (token counting, streaming) is unverified — test empirically.

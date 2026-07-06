# Observing traces

Every `/chat` turn runs under one **W3C trace**. `app/telemetry.py` exports that trace to a single
sink — **App Insights** (the central Log Analytics workspace) — including the prompt, retrieved
context, and completion for the turn. The one piece of unpredictable user-authored input — **the
user's own message** — is **PII-scrubbed before it leaves the app** (see
[How content is secured](#how-content-is-secured)).

| In the trace | Where | Read it for |
|--------------|-------|-------------|
| Timings, token counts, success/failure, the span tree | `AppRequests` / `AppDependencies` | "was it slow / did it fail / how many tokens", cross-tier correlation |
| Prompt (user's message **scrubbed**; system prompt, context, history as-is), retrieved docs, completion | `AppTraces` (the `gen_ai.content.*` span events) | reading what was asked/answered for a turn |

One trace ID keys all of it.

> The Azure AI Foundry portal's own "completions metadata" dashboard is **not** a trace view for this app — it reads Azure-OpenAI-collected usage and stays sparse here. Ignore it; use the queries below.

## 1. Get the trace ID

The chat UI prints it under every answer on purpose (`app/static/index.html`):

```
sources: E42 troubleshooting
trace_id: 171b4070efa1aeaf4b52d8750fb6bdf6
```

It's also the `trace_id` field of the raw `/chat` JSON response (grab it from DevTools → Network if the UI text is inconvenient to copy). That 32-hex value is the join key everywhere below.

## 2. Where the logs are, and the join key

App Insights writes to the central Log Analytics workspace in **`rg-ragchat-monitoring`**. The trace ID maps to **`OperationId`** in every table:

| Table | Spans | `AppRoleName` |
|-------|-------|---------------|
| `AppRequests` | server spans — the `chat` root **and** the APIM gateway operations | `rag-app`, `apim-…` |
| `AppDependencies` | client/internal spans — `retrieve`, `llm-call`, the httpx calls out to APIM | `rag-app` |
| `AppTraces` | span events, incl. the redacted `gen_ai.content.*` content records | `rag-app` |

Because `apim-ai.bicep` sets `httpCorrelationProtocol: 'W3C'`, a **single** trace ID spans app **and** gateway — `POST /chat` (`rag-app`) and `POST /ai/v1/chat/completions` + `/embeddings` (`apim-…`) share one `OperationId`. So one query reconstructs the whole app → gateway → model path.

## 3. Queries

### Recent requests (overview)

```kql
AppRequests
| where TimeGenerated > ago(1h)
| project TimeGenerated, AppRoleName, Name, Success, DurationMs, ResultCode, OperationId
| order by TimeGenerated desc
| take 50
```

Variations: `| where Success == false` for failures only; `| summarize count(), avg(DurationMs), p95=percentile(DurationMs, 95) by Name, AppRoleName` to profile.

### The span tree for one trace ID

Paste the trace ID from the UI into `tid`:

```kql
let tid = "171b4070efa1aeaf4b52d8750fb6bdf6";
union AppRequests, AppDependencies
| where OperationId == tid
| project TimeGenerated, Kind=Type, AppRoleName, Op=Name, Success, DurationMs, ResultCode, Id, ParentId
| order by TimeGenerated asc
```

`Id` / `ParentId` rebuild the span tree: root `chat` → `retrieve` / `llm-call` → the APIM operations.

### The content for one trace ID (redacted)

The prompt, retrieved docs, and completion are `gen_ai.content.*` span events, so they land in `AppTraces` with the payload in the `Properties.content` custom dimension:

```kql
let tid = "171b4070efa1aeaf4b52d8750fb6bdf6";
AppTraces
| where OperationId == tid and Message startswith "gen_ai.content"
| project TimeGenerated, Kind = Message, content = tostring(Properties.content)
| order by TimeGenerated asc
```

The `gen_ai.content.prompt` event is a JSON object — `{system_prompt, history, context, user_message}` — where **only `user_message`** is de-identified (PII replaced by realistic random stand-ins via the `syntheticReplacement` policy: `John Smith` → `Sam Johnson`). The other keys, and the `retrieval` and `completion` events, are the verbatim text.

## How content is secured

The one bit of content this app can't predict is what the user types, so that's what it scrubs. **Only the user's own message is de-identified**; everything else in the trace is exported as-is.

- **What's scrubbed:** the `user_message` field of the prompt event. `record_content(payload, scrub=("user_message",))` marks it, and `RedactingSpanExporter` scrubs just that field in the exporter, re-serializing the rest of the payload verbatim.
- **Azure AI Language — PII detection (NER),** the `syntheticReplacement` policy: each detected entity is swapped for a realistic random stand-in (`John Smith` → `Sam Johnson`) rather than masked to `****`, so traces stay readable. Keyless — the app calls `/language/:analyze-text` with an Entra token from its managed identity (`Cognitive Services User` on the Foundry account, a multi-service `AIServices` resource that also serves Language). Set by `LANGUAGE_ENDPOINT`. It's a **preview** policy, so `app/telemetry.py` pins the preview API version (`2025-11-15-preview`).
- **Fail closed.** If the Language call can't run — throttle, outage, over-length, or `LANGUAGE_ENDPOINT` unset — the `user_message` is **withheld** (`[content withheld: PII redaction unavailable]`), never exported raw.
- **What's NOT scrubbed — and why it's still OK:**
  - *Retrieved documents / `context`* — this is **your own corpus**. De-identify it once, at **ingestion** (before indexing), not on every chat turn. Until you add that, retrieved-doc PII reaches the workspace as-is.
  - *`completion`* — the model's answer can echo the user's input or document PII; it's exported as-is today.
  - *`history`* — prior user turns live here and aren't scrubbed (they're already stored raw in the Postgres `history` table).

  So treat the workspace itself as sensitive: **RBAC** (Reader / table-level access on `AppTraces`), **short retention**, and the **Purge API** — see below.

Scrubbing runs in the exporter on the `BatchSpanProcessor` background thread, so the Azure Language round-trip never touches the request path. Raw content lives only in-process on the span until that thread redacts it — nothing unredacted leaves the process. Locally (no `APPLICATIONINSIGHTS_CONNECTION_STRING`) nothing is exported at all.

### Harden the sink (operational)

Redaction is never perfect, so treat the workspace as sensitive too:

- **Access.** Reading content needs `Reader` / `Log Analytics Reader` on the workspace. For tighter control, use **table-level RBAC** to gate `AppTraces` separately from the ops tables, and prefer **resource-context** access so app owners see only their resource's rows.
- **Retention.** The workspace retains 30 days (`monitoring.bicep`, `retentionInDays`). Lower it, or set a shorter table-level retention on `AppTraces`, to shrink the window in which content exists.
- **Deletion.** For a subject-access/erasure request, use the [Purge API](https://learn.microsoft.com/en-us/rest/api/loganalytics/workspacepurge/purge) (`Data Purger` role) — batch identities with the `in` operator; the SLA is 30 days. See [Manage personal data in Azure Monitor Logs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/personal-data-mgmt).

## Running the queries

**Script (the easy path):** `scripts/telemetry.py` wraps the two common cases against Log Analytics — it resolves the workspace from the selected azd environment, so there are no names to paste:

```bash
uv run scripts/telemetry.py                  # §3 overview: errors, latency p50/p95, tokens (last 1h)
uv run scripts/telemetry.py --trace-id <id>  # §3 "everything for one trace", rendered as a span tree
```

It surfaces timings/status/tokens and the span tree, not the `gen_ai.content.*` events; for the redacted content of a turn, run the `AppTraces` query above ("the content for one trace ID"). Bypass azd with `--workspace <name-or-guid> --monitoring-rg <rg>` if you're not using an azd env.

**Portal** (best for exploring the span tree): Log Analytics workspace in `rg-ragchat-monitoring` → **Logs** → paste KQL.

**CLI:** resolve the workspace GUID once, then query. The workspace name is hashed, so look it up by resource group rather than hardcoding:

```bash
WS=$(az monitor log-analytics workspace list -g rg-ragchat-monitoring \
  --query "[0].customerId" -o tsv)
az monitor log-analytics query -w "$WS" --analytics-query '
  AppRequests | where TimeGenerated > ago(1h)
  | project TimeGenerated, AppRoleName, Name, Success, DurationMs, OperationId
  | order by TimeGenerated desc | take 50' -o table
```

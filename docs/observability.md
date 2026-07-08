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

### The content for one trace ID

The only content exported to telemetry is the **retrieved docs** — a `gen_ai.content.retrieval` span event that lands in `AppTraces` with the payload in the `Properties.content` custom dimension:

```kql
let tid = "171b4070efa1aeaf4b52d8750fb6bdf6";
AppTraces
| where OperationId == tid and Message startswith "gen_ai.content"
| project TimeGenerated, Kind = Message, content = tostring(Properties.content)
| order by TimeGenerated asc
```

## How content is secured

**App Insights holds zero conversation content.** The user's message, the model's answer, and the prior history all carry PII/PHI, so none of them are exported to telemetry — the only `gen_ai.content.*` event is `retrieval`, which is your own PII-free corpus.

- **The system of record for conversation content is Cosmos DB** (the `messages` container, `services/history.py`). Each turn is stored with its `trace_id`, so a trace in App Insights is still joinable back to the exact raw exchange — you look it up in Cosmos, keyed by `trace_id` / `session_id`, rather than reading it from the observability plane. This keeps PII in one access-controlled store (keyless, local-auth disabled) instead of scattered across telemetry.
- **What IS in telemetry:** the span tree, latency, token usage (`gen_ai.usage.*`), status, `session.id`, and the `retrieval` content (doc titles/text). No user- or model-authored free text.
- **Retrieved documents / `context`** are exported as-is — this is **your own corpus**, so de-identify it once at **ingestion** (before indexing), not per chat turn.
- **To inspect what a user asked / what the bot answered**, join a trace to Cosmos by `trace_id`. `record_content` is deliberately non-PII only (see `app/telemetry.py`); there is no PII-redaction step in the export path.

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

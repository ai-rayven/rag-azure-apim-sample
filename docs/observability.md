# Observing traces

Every `/chat` turn runs under one **W3C trace**. `app/telemetry.py` fans that trace out to two sinks:

| Sink | Contents | Use it for |
|------|----------|-----------|
| **Log Analytics** (App Insights) | redacted ops skeleton — timings, token counts, success/failure. `gen_ai.content.*` events are stripped by `RedactingSpanExporter` **before** they leave, so no prompt/completion/retrieval text lands in the shared workspace. | "was it slow / did it fail / how many tokens", cross-tier correlation |
| **Postgres `spans` table** | full-fidelity OTEL spans, **including content** — but only when `trace_content` is enabled. | reading the actual prompt, retrieved docs, and answer for a turn |

Same trace ID keys both. Start in Log Analytics; drop to Postgres when you need the text.

> The Azure AI Foundry portal's own "completions metadata" dashboard is **not** a trace view for this app — it reads Azure-OpenAI-collected usage and stays sparse here. Ignore it; use the queries below.

## 1. Get the trace ID

The chat UI prints it under every answer on purpose (`app/static/index.html`):

```
sources: E42 troubleshooting
trace_id: 171b4070efa1aeaf4b52d8750fb6bdf6
```

It's also the `trace_id` field of the raw `/chat` JSON response (grab it from DevTools → Network if the UI text is inconvenient to copy). That 32-hex value is the join key everywhere below.

## 2. Where the logs are, and the join key

App Insights writes to the central Log Analytics workspace in **`rg-ragchat-monitoring`**. The trace ID maps to **`OperationId`** in all three tables:

| Table | Spans | `AppRoleName` |
|-------|-------|---------------|
| `AppRequests` | server spans — the `chat` root **and** the APIM gateway operations | `rag-app`, `apim-…` |
| `AppDependencies` | client spans — `retrieve`, `llm-call`, the httpx calls out to APIM | `rag-app` |
| `AppTraces` | log records | `rag-app` |

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

### Everything for one trace ID

Paste the trace ID from the UI into `tid`:

```kql
let tid = "171b4070efa1aeaf4b52d8750fb6bdf6";
union AppRequests, AppDependencies, AppTraces
| where OperationId == tid
| project TimeGenerated, Kind=Type, AppRoleName,
          Op=coalesce(Name, Message), Success, DurationMs, ResultCode,
          Id, ParentId
| order by TimeGenerated asc
```

`Id` / `ParentId` rebuild the span tree: root `chat` → `retrieve` / `llm-call` → the APIM operations. This is the timing/status skeleton for that exact turn (no content — see §4).

## 4. Full-fidelity trace, with content (Postgres)

Log Analytics has no prompt/completion/retrieval text by design. For that, query the `spans` table with the **same** trace ID (stored as the same 32-hex string). Connect keyless with an Entra token, exactly as the app does (`PG_*` come from `azd env get-value PG_HOST` etc., or the generated `.env`):

```bash
export PGPASSWORD=$(az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net --query accessToken -o tsv)
psql "host=$PG_HOST dbname=$PG_DB user=$PG_USER sslmode=require" -c "
  SELECT start_time, name, kind, duration_ms, status_code, events
  FROM spans
  WHERE trace_id = '171b4070efa1aeaf4b52d8750fb6bdf6'
  ORDER BY start_time;"
```

The prompt, retrieved docs, and answer live in the `events` JSONB column as `gen_ai.content.*` events — **present only if `trace_content=true`** when the turn ran (opt-in; off by default so content isn't captured unless you ask for it).

## Running the queries

**Script (the easy path):** `scripts/telemetry.py` wraps the two common cases against Log Analytics — it resolves the workspace from the selected azd environment, so there are no names to paste:

```bash
uv run scripts/telemetry.py                  # §3 overview: errors, latency p50/p95, tokens (last 1h)
uv run scripts/telemetry.py --trace-id <id>  # §3 "everything for one trace", rendered as a span tree
```

It reads only Log Analytics (the redacted skeleton); for the content in §4 use the psql query above. Bypass azd with `--workspace <name-or-guid> --monitoring-rg <rg>` if you're not using an azd env.

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

> Reading Log Analytics needs `Reader` (or `Log Analytics Reader`) on the workspace. Reading `spans` needs the app's Postgres login roles — locally you run as *you*, so grant yourself the DB roles or run in Azure (see the README's "Run locally" note).

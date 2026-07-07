---
name: diagnose
description: Debug and triage the RAG app's health and traces via Log Analytics. Use when asked to check on the app, investigate errors / latency / token usage, or drill into a specific trace.
---

# Diagnose

Triage the deployed RAG app from its telemetry. Drive `scripts/telemetry.py` as the data
plane; you supply the judgment — spot the anomaly, pick a trace, follow it across tiers, form
a hypothesis.

## Architecture (what you're looking at)

Every `/chat` turn runs under **one W3C trace**. Because APIM propagates W3C correlation, a single
trace ID (`OperationId`) spans **app → APIM gateway → model**. The app exports to App Insights →
one central **Log Analytics workspace** in `rg-ragchat-monitoring`. Three tables key on `OperationId`:

| Table | Spans | Read for |
|-------|-------|----------|
| `AppRequests` | server: the `chat` root **and** APIM gateway ops | did it fail / how slow, per tier |
| `AppDependencies` | client: `retrieve`, `llm-call`, httpx → APIM | token usage, downstream calls |
| `AppTraces` | `gen_ai.content.*` events (prompt / context / completion) | what was asked & answered |

`scripts/telemetry.py` covers the first two (health + span tree). Content lives in `AppTraces` and
is read with KQL (step 4). `user_message` is PII-scrubbed; everything else is verbatim. Full
reference: `docs/observability.md`.

Keyless: queries run under the caller's `az login` identity (needs `Reader` on the workspace) and
resolve the workspace from the selected azd env — no names to paste.

## Workflow

1. **Health overview.** Start broad unless the user handed you a trace ID.
   ```bash
   uv run scripts/telemetry.py            # last 1h
   uv run scripts/telemetry.py --since 24h
   ```
   Read: error rate, p50/p95 by operation, token usage, and the **Recent failures** list — each
   row carries a `TraceId`. Call out what's off (a spiking p95, a non-zero error rate, a tier that's
   slow) rather than restating the table.

2. **Pick a trace.** Use a `TraceId` from the failures list, or one the user gave you (32-hex,
   printed under each chat answer). If nothing failed and the user has no ID, say the app looks
   healthy and stop — don't manufacture a trace to inspect.

3. **Drill into the trace.**
   ```bash
   uv run scripts/telemetry.py --trace-id <32-hex>
   ```
   Read the span tree top-down: `chat` (app) → `retrieve` / `llm-call` (app) → the APIM gateway
   ops → model. Locate the **first** span that failed or blew its latency budget — that tier owns
   the problem (e.g. a 401 at the APIM op = gateway auth, not the model; a slow `retrieve` = search,
   not the LLM).

4. **Read the content only if the failure needs it** (wrong answer, bad retrieval — not for a
   timeout or 5xx). Not covered by the script; query `AppTraces` directly:
   ```bash
   WS=$(az monitor log-analytics workspace list -g rg-ragchat-monitoring --query "[0].customerId" -o tsv)
   az monitor log-analytics query -w "$WS" --analytics-query '
     let tid = "<32-hex>";
     AppTraces
     | where OperationId == tid and Message startswith "gen_ai.content"
     | project TimeGenerated, Kind = Message, content = tostring(Properties.content)
     | order by TimeGenerated asc' -o table
   ```
   `gen_ai.content.prompt` is `{system_prompt, history, context, user_message}` — only
   `user_message` is de-identified (realistic stand-ins, not `****`). `retrieval` and `completion`
   are verbatim.

5. **Report a hypothesis, not a data dump.** Name the tier at fault, the evidence (span + timing /
   status / trace ID), and the likely cause. If it's ambiguous, say what you'd check next.

## Notes

- **Deterministic tool, no invented KQL.** Prefer `telemetry.py`; only hand-write KQL for content
  (step 4) or a query the script can't express — model it on `docs/observability.md`, don't guess.
- **Add `--json`** to either mode when you need to compute across rows rather than eyeball them.
- **Not signed in / wrong env:** the script fails fast and tells you (`az login`,
  `azd env select <name>`, or `--workspace <name-or-guid> --monitoring-rg <rg>`).
- **No trace found** usually means retention aged it out (workspace keeps 30 days) or a bad ID.

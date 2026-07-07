---
name: use
description: Use the deployed RAG app in a real browser (Playwright) — ask real questions through the UI as a user would, and capture each turn's trace_id. The general way to operate the live app end-to-end, whether to smoke-test it, triage/reproduce an issue, or hand traces to `diagnose`.
---

# Use

Operate the live chatbot the way a user does — in a real browser — and capture the
trace_id each answer prints so it can be handed to `diagnose`. Uses the Playwright MCP
browser tools; `scripts/open.sh` resolves the URL so there's one source of truth.

Requires: the Playwright MCP server enabled for this project, and `azd up` already run.

## 1. Open the app
    URL=$(bash scripts/open.sh app --print)   # resolves APP_URL from the selected azd env
Then `browser_navigate` to $URL. Take a `browser_snapshot` to confirm the chat UI loaded.

## 2. Ask, per query
- `browser_type` the question into the message box, submit (Enter / send button).
- Wait for the streamed answer to finish, then `browser_snapshot`.
- The UI prints `sources: …` and `trace_id: <32-hex>` under each answer — read the
  trace_id (and sources) straight from the snapshot. Keep the same tab to reuse the
  session across follow-up turns (tests history).

## 3. Diagnose each trace
Traces take ~30–60s to land in Log Analytics — wait, then for each trace_id run the
**diagnose** drill: `uv run scripts/telemetry.py --trace-id <id>`. Follow diagnose's
own workflow (span tree → first failing/slow tier → hypothesis).

## 4. Report
Per query: what was asked, the answer's sources, the trace_id, and the diagnose
verdict (tier at fault / healthy). Flag any turn whose answer looks wrong even if its
trace is green. If every trace is clean, say the app is healthy — don't invent problems.

## Notes
- Default query battery when the user gives none: one doc-grounded ask
  ("How do I fix error E42?"), one out-of-scope ask, one same-session follow-up.
- If the UI never shows an answer, screenshot the failure and check the browser
  console before diagnosing — the break may be client-side / gateway, not a trace.
- Telemetry semantics live in the `diagnose` skill and `docs/observability.md`.

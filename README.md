# Enterprise RAG chatbot on Azure — minimal, keyless sample

A RAG chatbot behind **API Management** with a shippable identity posture: managed identity everywhere,
the one secret in Key Vault, nothing in source control. One APIM gateway fronts both the app and the
model; ingestion is an event-driven Container Apps Job. Minimal SKUs, cheap to stand up and tear down.

```
Browser ─▶ APIM ─▶ Container App (FastAPI) ─▶ AI Search · Postgres
                        └─ APIM ─▶ Azure OpenAI      (all keyless, via managed identity)

Blob drop ─▶ Event Grid ─▶ queue ─▶ Ingestion Job (Docling parse → embed → AI Search)
```

## Deploy

Subscription-scoped, driven by the [Azure Developer CLI (`azd`)](https://aka.ms/azd). Prerequisites:
`az login` and `azd auth login`.

```bash
azd env new ragchat                # create an environment (baseName stays ragchat)
azd env set SEARCH_LOCATION eastus # AI Search region (split out — capacity is often exhausted separately)
azd up                             # provision (bicep) + build/push images (ACR) + deploy the app & job
```

`azd up` runs `scripts/preflight.sh` first (a preprovision hook), provisions the four resource groups,
then builds each service's image in ACR and rolls it out to the Container App (`ca-`) and ingestion Job
(`caj-`). Re-run `azd deploy` alone to ship a code change without re-provisioning.

```bash
uv run scripts/seed.py             # drop scripts/samples/*.md into Blob → ingests within ~30s
azd env get-value APP_URL          # the gateway; ask "How do I fix error E42?" — answer cites its sources
```

Optional: `APIM_PUBLISHER_EMAIL` defaults to a placeholder — `azd env set APIM_PUBLISHER_EMAIL you@example.com`
to use your own.

Tear everything down (incl. soft-delete purge of APIM / OpenAI / Key Vault):

```bash
azd down --purge
```

> Keeping `baseName=ragchat` in the same subscription means `azd` **adopts** an existing deployment
> (resource names derive from a subscription-stable hash, not the env name) — so this migrates a
> Makefile-era deployment in place rather than creating parallel resources.

## Run locally

Materialize a gitignored `.env` from the azd environment, then run each service as source:

```bash
azd env get-values > .env
echo "APIM_KEY=$(az keyvault secret show --vault-name $(azd env get-value KV_APP_NAME) \
  --name apim-subscription-key --query value -o tsv)" >> .env
cd app       && uv run uvicorn main:app --reload
cd ingestion && uv run python -m main
```

Locally you run as *you*: Blob works, but Search and Postgres are locked to the app's managed identity —
grant yourself those roles for full local end-to-end, or just run in Azure.

## Observe

Every chat turn runs under one W3C trace, fanned out to Log Analytics (redacted skeleton) and Postgres
(full fidelity, incl. content). Two ways in:

```bash
uv run scripts/telemetry.py                  # health overview (errors, latency p50/p95, tokens) — last 1h
uv run scripts/telemetry.py --trace-id <id>  # the full app → gateway → model span tree for one turn
```

`telemetry.py` resolves the workspace from the selected azd environment (no hardcoded names). Copy the
`trace_id` shown under any answer to follow it end-to-end — see
[docs/observability.md](docs/observability.md) for the underlying KQL and the Postgres content queries.

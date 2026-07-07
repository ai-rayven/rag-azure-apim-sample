# RAG Chat on Azure (Reference Sample)

A RAG chatbot behind **API Management** with a shippable identity posture: managed identity everywhere,
the one secret in Key Vault, nothing in source control. One APIM gateway fronts both the app and the
model; ingestion is an event-driven Container Apps Job. Minimal SKUs, cheap to stand up and tear down.

```
Browser ─▶ APIM ─▶ Container App (FastAPI) ─▶ AI Search · Postgres
                        └─ APIM ─▶ Azure OpenAI      (all keyless, via managed identity)

Blob drop ─▶ Event Grid ─▶ queue ─▶ Ingestion Job (Docling parse → embed → AI Search)
```

# Getting Started

Subscription-scoped, driven by the [Azure Developer CLI (`azd`)](https://aka.ms/azd). Prerequisites:
`az login` and `azd auth login`.

```bash
azd env new ragchat                # create an environment (baseName stays ragchat)
azd up                             # provision (bicep) + build/push images (ACR) + deploy the app & job
```

`azd up` runs `scripts/preflight.sh` first (a preprovision hook), provisions the four resource groups,
then builds each service's image in ACR and rolls it out to the Container App (`ca-`) and ingestion Job (`caj-`).

```bash
uv run scripts/seed.py             # drop scripts/samples/*.md into Blob → ingests within ~30s
bash scripts/open.sh app           # open the chatbot; ask "How do I fix error E42?" — answer cites its sources
```

Tear everything down (incl. soft-delete purge of APIM / OpenAI / Key Vault) with `azd down --purge`.

# Making Changes

Re-run `azd deploy` to ship code without re-provisioning; `azd up` after infra (`infrastructure/*.bicep`) edits.

For a faster inner loop, run a service as source against the live backends — but note `azd` is the path,
there's no standalone local mode (the `.env` below is materialized *from* the azd environment):

```bash
azd env get-values > .env
echo "APIM_KEY=$(az keyvault secret show --vault-name $(azd env get-value KV_APP_NAME) \
  --name apim-subscription-key --query value -o tsv)" >> .env
cd app && uv run uvicorn main:app --reload
```

Caveat: locally you run as *you*, and Search/Postgres are locked to the app's managed identity — so this
only exercises code paths that don't hit them unless you grant yourself those roles. For end-to-end, `azd up`.

# Debugging

Every chat turn runs under one W3C trace exported to App Insights (Log Analytics) — timings/tokens
plus the prompt, retrieved context, and completion. The **user's own message** is PII-scrubbed by
Azure AI Language before it leaves the app (fail closed — withheld if the scrub can't run); your own
documents are meant to be de-identified at ingestion, not here.

```bash
uv run scripts/telemetry.py                  # health overview (errors, latency p50/p95, tokens) — last 1h
uv run scripts/telemetry.py --trace-id <id>  # the full app → gateway → model span tree for one turn
bash scripts/open.sh workbook                # the same signals as an Azure Monitor workbook
```

`telemetry.py` resolves the workspace from the selected azd environment (no hardcoded names). Copy the
`trace_id` shown under any answer to follow it end-to-end — see
[docs/observability.md](docs/observability.md) for the underlying KQL and the redaction/hardening model.

# Troubleshooting

**AI Search capacity in the region** — Search defaults to your environment's location and capacity is
often exhausted separately from other services. Pin it to another region before `azd up`:

```bash
azd env set SEARCH_LOCATION eastus
```

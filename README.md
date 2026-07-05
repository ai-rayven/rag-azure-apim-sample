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

Subscription-scoped. Prerequisite: just `az login`. The root `Makefile` wraps the flow (`make help`).

```bash
make deploy      # 3 resource groups with placeholder images (APIM provisions in a few minutes)
make release     # build ./app + ./ingestion images, redeploy at the new tags
make seed        # drop scripts/samples/*.md into Blob → ingests within ~30s
make open        # opens the gateway; ask "How do I fix error E42?" — answer cites its sources
```

Delete the three resource groups to stop everything.

## Run locally

```bash
make env                                              # write a gitignored .env from deployment outputs
cd app       && uv run uvicorn main:app --reload
cd ingestion && uv run python -m main
```

Locally you run as *you*: Blob works, but Search and Postgres are locked to the app's managed identity —
grant yourself those roles for full local end-to-end, or just run in Azure.

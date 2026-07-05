FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Native libs Docling's models (torch / torchvision) load at runtime on the slim base.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgomp1 libglib2.0-0 libgl1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ingestion
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy TIKTOKEN_CACHE_DIR=/ingestion/.tiktoken

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

# Pre-bake the Docling layout + table models and the tiktoken encoding into the image, so the Job
# never downloads them on a cold start (only what this pipeline uses — no OCR, no formula/figure models).
RUN uv run python -c "from docling.utils.model_downloader import download_models; download_models(with_code_formula=False, with_picture_classifier=False, with_rapidocr=False)"
RUN uv run python -c "import tiktoken; tiktoken.encoding_for_model('text-embedding-3-large')"

COPY . .

CMD ["uv", "run", "python", "-m", "main"]

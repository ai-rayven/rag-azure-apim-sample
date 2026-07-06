# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "azure-identity>=1.19",
#     "azure-storage-blob>=12.23",
#     "python-dotenv>=1.0",
# ]
# ///
"""Seed the ingestion pipeline with the built-in demo documents.

Uploads every file in `scripts/samples/` to the Blob `documents` container. Because ingestion is
event-driven, each upload fires a BlobCreated event -> Event Grid -> queue -> KEDA starts the Job,
so the demo docs get parsed, chunked, embedded (via APIM) and pushed to AI Search automatically —
you don't start the Job by hand. This is exactly the real path a user takes: drop a file, it ingests.

Keyless: authenticates to Storage with your `az login` identity (the account has no keys). You need
Storage Blob Data Contributor on the account, which the deploying user gets by default.

    uv run scripts/seed.py                    # resolves STORAGE_ACCOUNT from the selected azd env
    STORAGE_ACCOUNT=<name> uv run scripts/seed.py    # standalone, explicit account

Point it at your own files instead of the samples with SAMPLES_DIR=/path/to/docs.
"""

import mimetypes
import os
import subprocess
import sys
from pathlib import Path

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def azd_env(key: str) -> str | None:
    """Read one value from the selected azd environment (.azure/<env>/.env). None if azd is absent
    or the key is unset — so an explicit env var / .env still wins and standalone use keeps working."""
    try:
        proc = subprocess.run(["azd", "env", "get-value", key],
                              capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None
    val = proc.stdout.strip()
    if proc.returncode != 0 or not val or val.upper().startswith("ERROR"):
        return None
    return val


ACCOUNT = os.getenv("STORAGE_ACCOUNT") or os.getenv("BLOB_ACCOUNT") or azd_env("STORAGE_ACCOUNT")
CONTAINER = os.getenv("BLOB_CONTAINER", "documents")
SAMPLES_DIR = Path(os.getenv("SAMPLES_DIR") or Path(__file__).parent / "samples")

def main() -> None:
    if not ACCOUNT:
        sys.exit("could not resolve STORAGE_ACCOUNT — select an azd env (`azd env select <name>`) "
                 "or export STORAGE_ACCOUNT")

    files = sorted(p for p in SAMPLES_DIR.iterdir() if p.is_file())
    if not files:
        sys.exit(f"no files to upload in {SAMPLES_DIR}")

    svc = BlobServiceClient(
        account_url=f"https://{ACCOUNT}.blob.core.windows.net",
        credential=DefaultAzureCredential(),
    )
    container = svc.get_container_client(CONTAINER)
    for path in files:
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        with path.open("rb") as fh:
            container.upload_blob(path.name, fh, overwrite=True, content_type=content_type)
        print(f"uploaded {path.name}")

    print(f"seeded {len(files)} document(s) into {ACCOUNT}/{CONTAINER} — ingestion triggers within ~30s")


if __name__ == "__main__":
    main()

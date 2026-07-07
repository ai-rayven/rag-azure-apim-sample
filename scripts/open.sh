#!/usr/bin/env bash
set -euo pipefail

# Open a deployed resource in the browser. Reads URLs from the selected azd environment
# (no hardcoded names) — run after `azd up`.
#   bash scripts/open.sh app        # the RAG chatbot (APIM gateway)
#   bash scripts/open.sh workbook   # the Azure Monitor observability workbook

target="${1:-app}"

case "$target" in
  app)
    url=$(azd env get-value APP_URL)
    ;;
  workbook)
    id=$(azd env get-value WORKBOOK_ID)
    url="https://portal.azure.com/#resource${id}/workbook"
    ;;
  *)
    echo "usage: $0 [app|workbook]" >&2
    exit 2
    ;;
esac

[ -n "${url:-}" ] || { echo "no URL for '${target}' — has 'azd up' run in this environment?" >&2; exit 1; }

# --print: resolve the URL only, don't launch a browser (for automation, e.g. the `use` skill
# driving Playwright — open.sh stays the one place that knows how to resolve the URL).
if [ "${2:-}" = "--print" ]; then echo "$url"; exit 0; fi

# open (macOS) / xdg-open (Linux); otherwise just print it.
if command -v open >/dev/null 2>&1; then open "$url"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
else echo "$url"
fi

# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Pull app health + per-trace telemetry from the central Log Analytics workspace.

Two modes, one script:

    uv run scripts/telemetry.py                          # health overview (last 1h)
    uv run scripts/telemetry.py --since 24h              # ... over a different window
    uv run scripts/telemetry.py --trace-id <32-hex>      # everything for one trace

Without --trace-id you get a health skeleton: request/failure counts, error rate, p50/p95
latency by operation, token usage, and recent failures *with their trace IDs* — copy one of
those IDs back into --trace-id to drill in. With --trace-id you get the span tree for that one
turn, spanning app -> APIM gateway -> model (they share an OperationId; see docs/observability.md).

This surfaces timings/status/tokens and the span tree — not the `gen_ai.content.*` events. Those
also land in Log Analytics (the `AppTraces` table), but PII-scrubbed; read them with the KQL in
docs/observability.md ("the content for one trace ID"). Add --json for machine-readable output.

Keyless: queries run under your `az login` identity via the `az` CLI. You need `Reader` (or
`Log Analytics Reader`) on the workspace in the monitoring resource group. Nothing here prints a
secret. Resource names come from the azd environment (`azd env get-value`) — nothing is hardcoded;
the selected azd env IS the deployment identity. Point at a specific env with `--environment`, or
bypass azd entirely with `--workspace <name-or-guid>` (plus `--monitoring-rg` for a name).
"""

import argparse
import json
import re
import subprocess
import sys

# Accept 1h / 90m / 24h / 7d — passed straight into KQL ago(). Reject anything else so a typo
# can't silently turn into a KQL error deep in a query.
SINCE_RE = re.compile(r"^\d+[mhd]$")


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def az(*args: str) -> str:
    """Run an `az` command, return stdout. Surface a readable error instead of a stack trace."""
    try:
        proc = subprocess.run(
            ["az", *args], capture_output=True, text=True, check=False
        )
    except FileNotFoundError:
        die("`az` CLI not found on PATH. Install the Azure CLI and run `az login`.")
    if proc.returncode != 0:
        err = proc.stderr.strip() or proc.stdout.strip()
        if "az login" in err or "AADSTS" in err or "not logged in" in err.lower():
            die("not signed in — run `az login` first.")
        die(f"az {' '.join(args)} failed:\n{err}")
    return proc.stdout.strip()


def azd_env(key: str, environment: str | None = None) -> str | None:
    """Read one value from the azd environment store (.azure/<env>/.env), populated from the bicep
    outputs on provision. Returns None if azd is absent, no env is selected, or the key is unset —
    callers fall back to explicit flags. `environment` targets a specific env instead of the default."""
    cmd = ["azd", "env", "get-value", key]
    if environment:
        cmd += ["-e", environment]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None  # azd not installed — let the caller decide (e.g. --workspace was given)
    val = proc.stdout.strip()
    # azd exits non-zero for a missing key and may echo "ERROR: ..." — treat both as absent.
    if proc.returncode != 0 or not val or val.upper().startswith("ERROR"):
        return None
    return val


def workspace_guid(environment: str | None, workspace: str | None, monitoring_rg: str | None) -> str:
    """Resolve the Log Analytics workspace GUID (customerId) that `az monitor log-analytics
    query -w` needs. Prefer explicit flags; otherwise read the azd environment."""
    # A bare GUID passed to --workspace is already what we need — no lookup.
    if workspace and re.fullmatch(r"[0-9a-fA-F-]{36}", workspace):
        return workspace

    name = workspace or azd_env("LOG_ANALYTICS_NAME", environment)
    rg = monitoring_rg or azd_env("MONITORING_RESOURCE_GROUP", environment)
    if not name or not rg:
        die("could not resolve the workspace from azd — select an env (`azd env select <name>`), "
            "pass `--environment <name>`, or give `--workspace <name-or-guid>` (+ `--monitoring-rg`).")
    guid = az("monitor", "log-analytics", "workspace", "show",
              "-g", rg, "-n", name, "--query", "customerId", "-o", "tsv")
    if not guid:
        die(f"no Log Analytics workspace '{name}' in resource group '{rg}'. Has `azd provision` run?")
    return guid


def kql(guid: str, query: str) -> list[dict]:
    """Run a KQL query, return rows as dicts (az flattens the result table to a JSON array)."""
    raw = az("monitor", "log-analytics", "query", "-w", guid,
             "--analytics-query", query, "-o", "json")
    if not raw:
        return []
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError:
        die("could not parse Log Analytics response as JSON.")
    return rows if isinstance(rows, list) else []


# ------------------------------------------------------------------------- output helpers

def table(rows: list[dict], columns: list[str], widths: dict[str, int] | None = None) -> None:
    """Minimal fixed-width table. `widths` caps a column (long cells are truncated with …)."""
    if not rows:
        print("  (none)")
        return
    widths = widths or {}

    def cell(row: dict, col: str) -> str:
        val = row.get(col)
        s = "" if val is None else str(val)
        cap = widths.get(col)
        if cap and len(s) > cap:
            s = s[: cap - 1] + "…"
        return s

    w = {c: len(c) for c in columns}
    for r in rows:
        for c in columns:
            w[c] = max(w[c], len(cell(r, c)))
    header = "  ".join(c.ljust(w[c]) for c in columns)
    print("  " + header)
    print("  " + "  ".join("-" * w[c] for c in columns))
    for r in rows:
        print("  " + "  ".join(cell(r, c).ljust(w[c]) for c in columns))


def section(title: str) -> None:
    print(f"\n\033[1m{title}\033[0m")


# ------------------------------------------------------------------------- stats mode

def run_stats(guid: str, since: str, limit: int, as_json: bool) -> None:
    # Server-side spans: the /chat root and the APIM gateway operations.
    requests = kql(guid, f"""
        AppRequests
        | where TimeGenerated > ago({since})
        | summarize Requests=count(), Failures=countif(Success==false),
                    P50=round(percentile(DurationMs,50),0),
                    P95=round(percentile(DurationMs,95),0),
                    AvgMs=round(avg(DurationMs),0) by AppRoleName, Name
        | extend ErrorRatePct=round(100.0*Failures/Requests,1)
        | order by Requests desc
    """)
    # Client-side spans: retrieve, llm-call, and the httpx calls out to APIM.
    deps = kql(guid, f"""
        AppDependencies
        | where TimeGenerated > ago({since})
        | summarize Calls=count(), Failures=countif(Success==false),
                    P50=round(percentile(DurationMs,50),0),
                    P95=round(percentile(DurationMs,95),0) by AppRoleName, Name
        | order by Calls desc
    """)
    # gen_ai token usage is set as span attributes on llm-call -> App Insights customDimensions.
    tokens = kql(guid, f"""
        AppDependencies
        | where TimeGenerated > ago({since})
        | extend inTok=toint(Properties['gen_ai.usage.input_tokens']),
                 outTok=toint(Properties['gen_ai.usage.output_tokens']),
                 model=tostring(Properties['gen_ai.request.model'])
        | where isnotnull(inTok) or isnotnull(outTok)
        | summarize Calls=count(), InTokens=sum(inTok), OutTokens=sum(outTok) by Model=model
        | order by Calls desc
    """)
    exceptions = kql(guid, f"""
        AppExceptions
        | where TimeGenerated > ago({since})
        | summarize Count=count() by ProblemId, AppRoleName
        | order by Count desc
        | take 10
    """)
    # Recent failures across server + client spans, each carrying its OperationId (= trace ID)
    # so you can copy one straight into --trace-id.
    failures = kql(guid, f"""
        union (AppRequests | extend K='request'), (AppDependencies | extend K='dependency')
        | where TimeGenerated > ago({since}) and Success == false
        | project TimeGenerated, K, AppRoleName, Op=Name, ResultCode, TraceId=OperationId
        | order by TimeGenerated desc
        | take {limit}
    """)

    if as_json:
        print(json.dumps({
            "window": since, "requests": requests, "dependencies": deps,
            "tokens": tokens, "exceptions": exceptions, "recent_failures": failures,
        }, indent=2, default=str))
        return

    total = sum(int(r.get("Requests", 0) or 0) for r in requests)
    failed = sum(int(r.get("Failures", 0) or 0) for r in requests)
    rate = f"{100.0 * failed / total:.1f}%" if total else "n/a"
    print(f"\n\033[1mHealth over the last {since}\033[0m  "
          f"— {total} requests, {failed} failed ({rate})")

    section("Requests (server spans)")
    table(requests, ["AppRoleName", "Name", "Requests", "Failures",
                     "ErrorRatePct", "P50", "P95", "AvgMs"],
          widths={"Name": 34, "AppRoleName": 16})

    section("Dependencies (client spans)")
    table(deps, ["AppRoleName", "Name", "Calls", "Failures", "P50", "P95"],
          widths={"Name": 34, "AppRoleName": 16})

    section("Token usage")
    table(tokens, ["Model", "Calls", "InTokens", "OutTokens"], widths={"Model": 28})

    section("Exceptions")
    table(exceptions, ["AppRoleName", "ProblemId", "Count"], widths={"ProblemId": 46})

    section(f"Recent failures (up to {limit}) — TraceId feeds --trace-id")
    table(failures, ["TimeGenerated", "K", "AppRoleName", "Op", "ResultCode", "TraceId"],
          widths={"Op": 26, "AppRoleName": 12})
    print()


# ------------------------------------------------------------------------- trace mode

def run_trace(guid: str, trace_id: str, as_json: bool) -> None:
    # union of the three tables that key on OperationId (docs/observability.md §3).
    rows = kql(guid, f"""
        let tid = '{trace_id}';
        union AppRequests, AppDependencies, AppTraces
        | where OperationId == tid
        | project TimeGenerated, Kind=Type, AppRoleName,
                  Op=coalesce(Name, Message), Success, DurationMs, ResultCode,
                  Id, ParentId
        | order by TimeGenerated asc
    """)

    if as_json:
        print(json.dumps({"trace_id": trace_id, "spans": rows}, indent=2, default=str))
        return

    if not rows:
        print(f"\nNo telemetry found for trace {trace_id}.")
        print("It may have aged out of retention, or the ID is wrong. "
              "For prompt/completion content, query the `gen_ai.content.*` events in "
              "AppTraces (docs/observability.md §3).")
        return

    print(f"\n\033[1mTrace {trace_id}\033[0m")

    # Split log records (AppTraces have no span Id) from spans; render spans as a parent/child
    # tree and list logs separately in time order.
    spans = [r for r in rows if r.get("Id")]
    logs = [r for r in rows if not r.get("Id")]

    children: dict[str | None, list[dict]] = {}
    ids = {r["Id"] for r in spans}
    for r in spans:
        parent = r.get("ParentId")
        # Treat a parent that isn't in this trace's result set as a root.
        key = parent if parent in ids else None
        children.setdefault(key, []).append(r)

    def fmt(r: dict) -> str:
        dur = r.get("DurationMs")
        dur_s = f"{float(dur):.0f}ms" if dur not in (None, "") else "-"
        status = "ok" if r.get("Success") in (True, "true", "True") else \
                 (r.get("ResultCode") or "FAIL")
        role = r.get("AppRoleName") or "?"
        return f"{r.get('Op') or '(unnamed)'}  [{role}]  {dur_s}  {status}"

    def walk(parent_key: str | None, depth: int) -> None:
        for r in sorted(children.get(parent_key, []), key=lambda x: x.get("TimeGenerated") or ""):
            print("  " + "  " * depth + "• " + fmt(r))
            walk(r["Id"], depth + 1)

    section("Span tree (app → gateway → model)")
    walk(None, 0)

    if logs:
        section("Logs")
        table(logs, ["TimeGenerated", "AppRoleName", "Op"], widths={"Op": 80})
    print()


# ------------------------------------------------------------------------- entrypoint

def main() -> None:
    p = argparse.ArgumentParser(
        description="App telemetry from Log Analytics: health overview, or one trace's span tree.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--trace-id", help="32-hex trace ID; when set, show that trace instead of stats.")
    p.add_argument("--since", default="1h",
                   help="stats window as <n>m|h|d (default 1h). Ignored with --trace-id.")
    p.add_argument("--limit", type=int, default=20,
                   help="max recent failures to list in stats mode (default 20).")
    p.add_argument("--environment",
                   help="azd environment to read config from (default: the selected azd env).")
    p.add_argument("--workspace",
                   help="Log Analytics workspace name or GUID — bypasses azd resolution.")
    p.add_argument("--monitoring-rg",
                   help="resource group of the workspace (needed with a --workspace *name*).")
    p.add_argument("--json", action="store_true", dest="as_json",
                   help="emit raw JSON instead of tables.")
    args = p.parse_args()

    # Validate inputs before touching the network so a typo fails fast.
    if args.trace_id:
        args.trace_id = args.trace_id.strip().lower()
        if not re.fullmatch(r"[0-9a-f]{32}", args.trace_id):
            die("--trace-id must be a 32-character hex string (shown under a chat answer).")
    elif not SINCE_RE.match(args.since):
        die("--since must look like 15m, 1h, 24h, or 7d.")

    guid = workspace_guid(args.environment, args.workspace, args.monitoring_rg)
    if args.trace_id:
        run_trace(guid, args.trace_id, args.as_json)
    else:
        run_stats(guid, args.since, args.limit, args.as_json)


if __name__ == "__main__":
    main()

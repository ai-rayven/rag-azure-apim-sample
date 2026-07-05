#!/usr/bin/env bash
set -uo pipefail

LOCATION="${LOCATION:-eastus2}"

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; X=$'\033[0m'; else G=; Y=; R=; B=; X=; fi
fails=0 warns=0
pass() { printf "  ${G}✓${X} %s\n" "$1"; }
warn() { printf "  ${Y}!${X} %s\n" "$1"; warns=$((warns+1)); }
fail() { printf "  ${R}✗${X} %s\n" "$1"; fails=$((fails+1)); }
head() { printf "\n${B}%s${X}\n" "$1"; }

printf "${B}Preflight — RAG-on-APIM, region ${LOCATION}${X}\n"

# --- 1. tooling --------------------------------------------------------------
head "Tooling"
if command -v az >/dev/null 2>&1; then pass "az CLI present"; else fail "az CLI not found — install the Azure CLI"; fi
if az bicep version >/dev/null 2>&1; then pass "bicep present"; else warn "bicep not installed — 'az bicep install' (deploy will also auto-install it)"; fi
if command -v uv >/dev/null 2>&1; then pass "uv present"; else warn "uv not found — only needed for 'make seed'"; fi

# Everything below needs az; bail early if it's missing.
command -v az >/dev/null 2>&1 || { head "Result"; fail "cannot continue without az CLI"; exit 1; }

# --- 2. identity -------------------------------------------------------------
head "Identity"
if acct=$(az account show -o tsv --query "[name, id, user.name]" 2>/dev/null); then
  # A JMESPath multiselect list prints one element per line in TSV, so read line-by-line (not cut -f).
  { read -r sub_name; read -r sub_id; read -r who; } <<< "$acct"
  pass "logged in as ${who}"
  pass "target subscription: ${sub_name} (${sub_id})"
else
  fail "not logged in — run 'az login' (and 'az account set --subscription <name>')"
  head "Result"; exit 1
fi

# --- 3. deployer role --------------------------------------------------------
head "Deployer role (RBAC assignments need Owner or User Access Administrator)"
me=$(az ad signed-in-user show --query id -o tsv 2>/dev/null)
roles=$(az role assignment list --assignee "$me" --scope "/subscriptions/${sub_id}" --query "[].roleDefinitionName" -o tsv 2>/dev/null)
if echo "$roles" | grep -qxE "Owner|User Access Administrator"; then
  pass "have $(echo "$roles" | grep -xE 'Owner|User Access Administrator' | sort -u | paste -sd, -) at subscription scope"
else
  warn "no Owner/User Access Administrator at subscription scope (found: ${roles:-none}) — deploy's role assignments will fail unless you have it via a management group"
fi

# --- 4. AI Search free tier (one per subscription) ---------------------------
head "AI Search free tier (one per subscription)"
free_hit=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  sku=$(az resource show --ids "$id" --query sku.name -o tsv 2>/dev/null)
  if [ "$sku" = "free" ]; then warn "a free search service already exists: ${id##*/} — delete it or the deploy conflicts"; free_hit=1; fi
done < <(az resource list --resource-type Microsoft.Search/searchServices --query "[].id" -o tsv 2>/dev/null)
[ "$free_hit" -eq 0 ] && pass "no existing free search service found"

# --- 5. resource providers ---------------------------------------------------
head "Resource provider registration"
unreg=""
for ns in Microsoft.ManagedIdentity Microsoft.ApiManagement Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.CognitiveServices Microsoft.Search \
          Microsoft.ContainerRegistry Microsoft.App Microsoft.DBforPostgreSQL \
          Microsoft.Storage Microsoft.KeyVault Microsoft.EventGrid; do
  state=$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null)
  [ "$state" != "Registered" ] && unreg="${unreg} ${ns}"
done
if [ -z "$unreg" ]; then
  pass "all required providers registered"
else
  warn "not registered:${unreg}"
  warn "register with:$(for n in $unreg; do printf ' az provider register --namespace %s &&' "$n"; done | sed 's/ &&$//')"
fi

# --- result ------------------------------------------------------------------
head "Result"
if [ "$fails" -gt 0 ]; then
  fail "${fails} blocking issue(s), ${warns} warning(s) — resolve the ✗ items before 'make deploy'"
  exit 1
elif [ "$warns" -gt 0 ]; then
  warn "${warns} warning(s) — review the ! items, then you're clear to 'make deploy'"
  exit 0
else
  pass "all clear — run 'make whatif' then 'make deploy'"
  exit 0
fi

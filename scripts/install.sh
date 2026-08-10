#!/usr/bin/env bash
# Install / configure Apologist Generate Reply in a Salesforce org via sf + Connect API.
#
# Automates:
#   - Deploy LWC, Apex, Named/External Credential stubs, permission set, remote site
#   - Assign Apologist_Agent_Callout
#   - Set Named Credential callout URL
#   - Ensure External Credential custom header x-api-key
#   - Inject Agent API key into External Credential principal (ApiKey)
#
# Does not automate:
#   - Messaging / Omni-Channel org setup
#   - Placing the LWC on a Messaging Session Lightning page (App Builder)
#
# Usage:
#   ./scripts/install.sh --org apg-sf \
#     --agent-url https://your-agent.example.com \
#     --api-key "$APOLOGIST_API_KEY"
#
# Env fallbacks: SF_TARGET_ORG, APOLOGIST_AGENT_URL, APOLOGIST_API_KEY

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_VERSION="${SF_API_VERSION:-67.0}"

ORG="${SF_TARGET_ORG:-}"
AGENT_URL="${APOLOGIST_AGENT_URL:-}"
API_KEY="${APOLOGIST_API_KEY:-}"
ASSIGN_USER=""
SKIP_DEPLOY=0
SKIP_PERMSET=0
FULL_PROJECT=0
DRY_RUN=0

EXTERNAL_CRED="Apologist_Agent"
NAMED_CRED="Apologist_Agent"
PRINCIPAL="ApologistAgentPrincipal"
PERMSET="Apologist_Agent_Callout"
HEADER_NAME="x-api-key"
CRED_PARAM="ApiKey"

usage() {
  cat <<'EOF'
Install Apologist Generate Reply into a Salesforce org.

Required:
  --org, -o           Salesforce org alias or username
  --agent-url         Agent origin only (https://host, no /api/v1)
  --api-key           Agent API key (or set APOLOGIST_API_KEY)

Optional:
  --assign-user       Username to receive the callout permission set
                      (default: the authenticated org user)
  --skip-deploy       Skip metadata deploy (configure credentials only)
  --skip-permset      Skip permission set assignment
  --full-project      Deploy entire force-app (default: component stack only)
  --dry-run           Print actions without deploying or calling APIs
  -h, --help          Show this help

Environment:
  SF_TARGET_ORG, APOLOGIST_AGENT_URL, APOLOGIST_API_KEY, SF_API_VERSION
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

normalize_agent_url() {
  local url="$1"
  url="${url%%/}"
  url="${url%/api/v1}"
  url="${url%%/}"
  case "$url" in
    https://*|http://*) ;;
    *) die "Agent URL must start with https:// (got: $url)" ;;
  esac
  printf '%s' "$url"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--org) ORG="${2:-}"; shift 2 ;;
    --agent-url) AGENT_URL="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --assign-user) ASSIGN_USER="${2:-}"; shift 2 ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-permset) SKIP_PERMSET=1; shift ;;
    --full-project) FULL_PROJECT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

need_cmd sf
need_cmd curl
need_cmd python3

[[ -n "$ORG" ]] || die "Pass --org or set SF_TARGET_ORG"
[[ -n "$AGENT_URL" ]] || die "Pass --agent-url or set APOLOGIST_AGENT_URL"
[[ -n "$API_KEY" ]] || die "Pass --api-key or set APOLOGIST_API_KEY"

AGENT_URL="$(normalize_agent_url "$AGENT_URL")"

log "Target org: $ORG"
log "Agent URL:  $AGENT_URL"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run — no deploy, permset, or Connect API calls"
fi

# --- Deploy -----------------------------------------------------------------

deploy_stack() {
  if [[ "$SKIP_DEPLOY" -eq 1 ]]; then
    log "Skipping metadata deploy (--skip-deploy)"
    return
  fi

  if [[ "$FULL_PROJECT" -eq 1 ]]; then
    log "Deploying full force-app"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "sf project deploy start -o $ORG --source-dir force-app"
      return
    fi
    (cd "$ROOT" && sf project deploy start -o "$ORG" --source-dir force-app)
  else
    log "Deploying component stack (LWC, Apex, credentials, permset, remote site)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "sf project deploy start -o $ORG --source-dir …"
      return
    fi
    (cd "$ROOT" && sf project deploy start -o "$ORG" \
      --source-dir force-app/main/default/lwc/apgGenerateReply \
      --source-dir force-app/main/default/classes \
      --source-dir force-app/main/default/namedCredentials \
      --source-dir force-app/main/default/externalCredentials \
      --source-dir force-app/main/default/permissionsets \
      --source-dir force-app/main/default/remoteSiteSettings)
  fi
}

# --- Permission set ---------------------------------------------------------

assign_permset() {
  if [[ "$SKIP_PERMSET" -eq 1 ]]; then
    log "Skipping permission set assignment (--skip-permset)"
    return
  fi

  local user="$ASSIGN_USER"
  if [[ -z "$user" ]]; then
    user="$(sf org display -o "$ORG" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])")"
  fi

  log "Assigning permission set $PERMSET to $user"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "sf org assign permset -n $PERMSET -o $ORG -b $user"
    return
  fi
  sf org assign permset -n "$PERMSET" -o "$ORG" -b "$user"
}

# --- Connect API helpers ----------------------------------------------------

sf_instance_url() {
  sf org display -o "$ORG" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['instanceUrl'])"
}

sf_access_token() {
  sf org auth show-access-token -o "$ORG" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['accessToken'])"
}

connect_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local instance token url
  instance="$(sf_instance_url)"
  token="$(sf_access_token)"
  url="${instance}/services/data/v${API_VERSION}${path}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "$method $url"
    [[ -n "$body" ]] && printf '%s\n' "$body"
    return 0
  fi

  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

ensure_custom_header() {
  log "Ensuring External Credential custom header ${HEADER_NAME}"
  local current desired
  current="$(connect_request GET "/named-credentials/external-credentials/${EXTERNAL_CRED}")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  desired="$(AGENT_URL="$AGENT_URL" EXTERNAL_CRED="$EXTERNAL_CRED" PRINCIPAL="$PRINCIPAL" HEADER_NAME="$HEADER_NAME" CRED_PARAM="$CRED_PARAM" CURRENT="$current" python3 - <<'PY'
import json, os
current = json.loads(os.environ["CURRENT"])
header_name = os.environ["HEADER_NAME"]
merge = "{!$Credential.%s.%s}" % (os.environ["EXTERNAL_CRED"], os.environ["CRED_PARAM"])
headers = list(current.get("customHeaders") or [])
found = False
for h in headers:
    if h.get("headerName") == header_name:
        h["headerValue"] = merge
        found = True
        break
if not found:
    headers.append({
        "headerName": header_name,
        "headerValue": merge,
        "sequenceNumber": len(headers) + 1,
    })
body = {
    "authenticationProtocol": current.get("authenticationProtocol") or "Custom",
    "developerName": os.environ["EXTERNAL_CRED"],
    "masterLabel": current.get("masterLabel") or "Apologist Agent",
    "customHeaders": [
        {
            "headerName": h["headerName"],
            "headerValue": h["headerValue"],
            "sequenceNumber": h.get("sequenceNumber") or i + 1,
        }
        for i, h in enumerate(headers)
    ],
    "principals": [
        {
            "principalName": p.get("principalName"),
            "principalType": p.get("principalType") or "NamedPrincipal",
            "sequenceNumber": p.get("sequenceNumber") or 1,
        }
        for p in (current.get("principals") or [{
            "principalName": os.environ["PRINCIPAL"],
            "principalType": "NamedPrincipal",
            "sequenceNumber": 1,
        }])
    ],
}
print(json.dumps(body))
PY
)"

  local resp
  resp="$(connect_request PUT "/named-credentials/external-credentials/${EXTERNAL_CRED}" "$desired")"
  if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); raise SystemExit(1 if isinstance(d,list) else 0)" 2>/dev/null; then
    die "Failed to update External Credential headers: $resp"
  fi
}

set_named_credential_url() {
  log "Setting Named Credential URL"
  local current body resp
  current="$(connect_request GET "/named-credentials/named-credential-setup/${NAMED_CRED}")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  body="$(CURRENT="$current" AGENT_URL="$AGENT_URL" NAMED_CRED="$NAMED_CRED" EXTERNAL_CRED="$EXTERNAL_CRED" python3 - <<'PY'
import json, os
current = json.loads(os.environ["CURRENT"])
opts = current.get("calloutOptions") or {}
body = {
    "calloutUrl": os.environ["AGENT_URL"],
    "developerName": os.environ["NAMED_CRED"],
    "masterLabel": current.get("masterLabel") or "Apologist Agent",
    "type": current.get("type") or "SecuredEndpoint",
    "calloutStatus": current.get("calloutStatus") or "Enabled",
    "calloutOptions": {
        "allowMergeFieldsInBody": bool(opts.get("allowMergeFieldsInBody", False)),
        "allowMergeFieldsInHeader": True,
        "generateAuthorizationHeader": bool(opts.get("generateAuthorizationHeader", False)),
    },
    "externalCredentials": [
        {"developerName": os.environ["EXTERNAL_CRED"]}
    ],
}
print(json.dumps(body))
PY
)"

  resp="$(connect_request PUT "/named-credentials/named-credential-setup/${NAMED_CRED}" "$body")"
  if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); raise SystemExit(1 if isinstance(d,list) else 0)" 2>/dev/null; then
    die "Failed to set Named Credential URL: $resp"
  fi
}

is_sf_error_response() {
  # Salesforce Connect errors are JSON arrays of {message,errorCode}
  printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if isinstance(d,list) else 1)"
}

inject_api_key() {
  log "Injecting API key into External Credential principal (${CRED_PARAM})"
  local body resp
  body="$(API_KEY="$API_KEY" EXTERNAL_CRED="$EXTERNAL_CRED" PRINCIPAL="$PRINCIPAL" CRED_PARAM="$CRED_PARAM" python3 - <<'PY'
import json, os
print(json.dumps({
    "externalCredential": os.environ["EXTERNAL_CRED"],
    "principalName": os.environ["PRINCIPAL"],
    "principalType": "NamedPrincipal",
    "authenticationProtocol": "Custom",
    "credentials": {
        os.environ["CRED_PARAM"]: {
            "value": os.environ["API_KEY"],
            "encrypted": True,
        }
    },
}))
PY
)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    connect_request POST "/named-credentials/credential/" '{"credentials":{"ApiKey":{"value":"[redacted]","encrypted":true}}}'
    return
  fi

  resp="$(connect_request POST "/named-credentials/credential/" "$body")"
  if is_sf_error_response "$resp"; then
    log "POST failed (likely already exists); updating via PATCH"
    resp="$(connect_request PATCH "/named-credentials/credential/" "$body")"
  fi
  if is_sf_error_response "$resp"; then
    die "Failed to inject API key: $resp"
  fi
}

update_remote_site() {
  log "Updating Remote Site Setting URL (optional stub)"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/remoteSiteSettings"
  cat >"$tmp/remoteSiteSettings/Apologist_Agent.remoteSite-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <disableProtocolSecurity>false</disableProtocolSecurity>
    <isActive>true</isActive>
    <url>${AGENT_URL}</url>
    <description>Fallback remote site for Apologist Agent API callouts. Prefer the Apologist_Agent Named Credential.</description>
</RemoteSiteSetting>
EOF
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "sf project deploy start -o $ORG --source-dir $tmp/remoteSiteSettings"
    rm -rf "$tmp"
    return
  fi
  if ! sf project deploy start -o "$ORG" --source-dir "$tmp/remoteSiteSettings" >/dev/null; then
    warn "Remote Site Setting update failed (safe to ignore when using Named Credentials)"
  fi
  rm -rf "$tmp"
}

# --- Run --------------------------------------------------------------------

deploy_stack
assign_permset

if [[ "$DRY_RUN" -eq 1 ]]; then
  ensure_custom_header
  set_named_credential_url
  inject_api_key
  update_remote_site
else
  # Credentials APIs need the metadata present first
  ensure_custom_header
  set_named_credential_url
  inject_api_key
  update_remote_site
fi

cat <<EOF

Install finished for org: $ORG

Next (manual):
  1. Open a Messaging Session record → Edit Page
  2. Add "Apologist Generate Reply" (ensure Enhanced Conversation is on the page)
  3. Set Title / Description / Icon / Past messages as needed
  4. Save & Activate
  5. Accept an Active messaging session and click Generate Draft Reply

EOF

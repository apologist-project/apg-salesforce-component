#!/usr/bin/env bash
# Install / configure Apologist Generate Reply in a Salesforce org via sf + Connect API.
#
# Automates:
#   - Deploy LWC, Apex, Named/External Credential stubs, permission set, remote site
#   - Assign Apologist_Agent_Callout
#   - Configure Messaging and/or Case Named Credentials (URL + x-api-key)
#
# Does not automate:
#   - Messaging / Omni-Channel org setup
#   - Placing the LWC on Lightning pages (App Builder)
#
# Usage (pick a context with --for + shared agent):
#   ./scripts/install.sh --org apg-sf --for messaging \
#     --agent-url https://chat-agent.example.com \
#     --api-key "$CHAT_KEY"
#
#   ./scripts/install.sh --org apg-sf --for case \
#     --agent-url https://email-agent.example.com \
#     --api-key "$EMAIL_KEY" \
#     --activate-case-page
#
#   ./scripts/install.sh --org apg-sf --for case \
#     --agent-url https://email-agent.example.com \
#     --api-key "$EMAIL_KEY" \
#     --case-page Case_Record_Page1
#
#   ./scripts/install.sh --org apg-sf --for both \
#     --agent-url https://your-agent.example.com \
#     --api-key "$APOLOGIST_API_KEY"
#
# Usage (separate agents without --for):
#   ./scripts/install.sh --org apg-sf \
#     --messaging-agent-url https://chat-agent.example.com \
#     --messaging-api-key "$CHAT_KEY" \
#     --case-agent-url https://email-agent.example.com \
#     --case-api-key "$EMAIL_KEY"
#
# Env fallbacks: SF_TARGET_ORG, APOLOGIST_AGENT_URL, APOLOGIST_API_KEY,
#   APOLOGIST_MESSAGING_AGENT_URL, APOLOGIST_MESSAGING_API_KEY,
#   APOLOGIST_CASE_AGENT_URL, APOLOGIST_CASE_API_KEY,
#   APOLOGIST_INSTALL_FOR (messaging|case|both),
#   APOLOGIST_CASE_PAGE, APOLOGIST_ACTIVATE_CASE_PAGE (1 to activate)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_VERSION="${SF_API_VERSION:-67.0}"
DEFAULT_CASE_PAGE="Case_Record_Page"

ORG="${SF_TARGET_ORG:-}"
SHARED_AGENT_URL="${APOLOGIST_AGENT_URL:-}"
SHARED_API_KEY="${APOLOGIST_API_KEY:-}"
MESSAGING_AGENT_URL="${APOLOGIST_MESSAGING_AGENT_URL:-}"
MESSAGING_API_KEY="${APOLOGIST_MESSAGING_API_KEY:-}"
CASE_AGENT_URL="${APOLOGIST_CASE_AGENT_URL:-}"
CASE_API_KEY="${APOLOGIST_CASE_API_KEY:-}"
INSTALL_FOR="${APOLOGIST_INSTALL_FOR:-}"
CASE_PAGE="${APOLOGIST_CASE_PAGE:-$DEFAULT_CASE_PAGE}"
ASSIGN_USER=""
SKIP_DEPLOY=0
SKIP_PERMSET=0
SKIP_CASE_PAGE=0
FULL_PROJECT=0
DRY_RUN=0
CONFIGURE_LEGACY=0
INCLUDE_CASE_PAGE=0
ACTIVATE_CASE_PAGE=0

if [[ "${APOLOGIST_ACTIVATE_CASE_PAGE:-}" == "1" ]]; then
  ACTIVATE_CASE_PAGE=1
fi

PERMSET="Apologist_Agent_Callout"
HEADER_NAME="x-api-key"
CRED_PARAM="ApiKey"
PRINCIPAL="ApologistAgentPrincipal"

usage() {
  cat <<'EOF'
Install Apologist Generate Reply into a Salesforce org.

Org:
  --org, -o                 Salesforce org alias or username

Context (optional sugar for a single Agent URL/key):
  --for messaging|case|both Which Named Credential(s) to configure with
                            --agent-url / --api-key
                            Aliases: chat→messaging, email→case, all→both
                            Default without --for: both (+ legacy), same as --for both

Agent credentials (API keys stay in External Credentials — never in the LWC):
  --agent-url / --api-key   Agent origin + API key (scoped by --for)

  --messaging-agent-url / --messaging-api-key
                            Configure Apologist_Agent_Messaging (overrides --for for messaging)
  --case-agent-url / --case-api-key
                            Configure Apologist_Agent_Case (overrides --for for case)

At least one complete URL+key pair is required after applying --for.

Optional:
  --assign-user             Username for the callout permission set
  --skip-deploy             Configure credentials only (no metadata deploy)
  --skip-permset            Skip permission set assignment
  --skip-case-page          Do not deploy Case Quick Action / layout / page wiring
  --case-page NAME          Activate Lightning Case page NAME as org default View
                            (implies --activate-case-page; default NAME: Apologist_Case_Page)
  --activate-case-page      Activate org default Case View (uses --case-page or
                            Apologist_Case_Page). Off by default — customer orgs usually
                            keep their own Case page and add actions in App Builder.
  --full-project            Deploy entire force-app
  --dry-run                 Print actions without changing the org
  -h, --help                Show this help

When installing for case/email (--for case|both, or --case-agent-*), the script also
deploys the Case Quick Action and wires it onto Case layouts + Lightning pages
(highlights panel). Org-default Case page activation is opt-in via --activate-case-page
or --case-page. LWC actions cannot be dragged onto the classic Quick Action list.

Per-instance Agents:
  Create additional Named Credentials in Setup, then set the component's
  App Builder property "Named Credential" to that API name.
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

normalize_install_for() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    messaging|chat) printf 'messaging' ;;
    case|email) printf 'case' ;;
    both|all) printf 'both' ;;
    *) die "Invalid --for value: $1 (use messaging, case, or both)" ;;
  esac
}

validate_case_page_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || \
    die "Invalid Case Lightning page API name: $name (use the FlexiPage DeveloperName)"
}

# Writes Case View actionOverrides for Desktop + Phone targeting the given FlexiPage.
write_case_view_override() {
  local page="$1"
  local dest="$ROOT/force-app/main/default/objects/Case/Case.object-meta.xml"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Org default Case Lightning page with Apologist Generate Draft Reply.</comment>
        <content>${page}</content>
        <formFactor>Large</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Org default Case Lightning page with Apologist Generate Draft Reply.</comment>
        <content>${page}</content>
        <formFactor>Small</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
    </actionOverrides>
</CustomObject>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--org) ORG="${2:-}"; shift 2 ;;
    --for) INSTALL_FOR="${2:-}"; shift 2 ;;
    --agent-url) SHARED_AGENT_URL="${2:-}"; shift 2 ;;
    --api-key) SHARED_API_KEY="${2:-}"; shift 2 ;;
    --messaging-agent-url) MESSAGING_AGENT_URL="${2:-}"; shift 2 ;;
    --messaging-api-key) MESSAGING_API_KEY="${2:-}"; shift 2 ;;
    --case-agent-url) CASE_AGENT_URL="${2:-}"; shift 2 ;;
    --case-api-key) CASE_API_KEY="${2:-}"; shift 2 ;;
    --assign-user) ASSIGN_USER="${2:-}"; shift 2 ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-permset) SKIP_PERMSET=1; shift ;;
    --skip-case-page) SKIP_CASE_PAGE=1; shift ;;
    --case-page)
      CASE_PAGE="${2:-}"
      [[ -n "$CASE_PAGE" ]] || die "--case-page requires a Lightning page API name"
      ACTIVATE_CASE_PAGE=1
      shift 2
      ;;
    --activate-case-page) ACTIVATE_CASE_PAGE=1; shift ;;
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

# Default --for both when using the shared pair with no explicit context flags.
if [[ -z "$INSTALL_FOR" && -n "$SHARED_AGENT_URL$SHARED_API_KEY" && -z "$MESSAGING_AGENT_URL$MESSAGING_API_KEY$CASE_AGENT_URL$CASE_API_KEY" ]]; then
  INSTALL_FOR="both"
fi

if [[ -n "$INSTALL_FOR" ]]; then
  INSTALL_FOR="$(normalize_install_for "$INSTALL_FOR")"
fi

# Shared pair scoped by --for (or default both).
if [[ -n "$SHARED_AGENT_URL" || -n "$SHARED_API_KEY" ]]; then
  [[ -n "$SHARED_AGENT_URL" && -n "$SHARED_API_KEY" ]] || \
    die "Both --agent-url and --api-key are required when using the shared pair"
  SHARED_AGENT_URL="$(normalize_agent_url "$SHARED_AGENT_URL")"

  local_for="${INSTALL_FOR:-both}"
  case "$local_for" in
    messaging)
      [[ -z "$MESSAGING_AGENT_URL" ]] && MESSAGING_AGENT_URL="$SHARED_AGENT_URL"
      [[ -z "$MESSAGING_API_KEY" ]] && MESSAGING_API_KEY="$SHARED_API_KEY"
      ;;
    case)
      [[ -z "$CASE_AGENT_URL" ]] && CASE_AGENT_URL="$SHARED_AGENT_URL"
      [[ -z "$CASE_API_KEY" ]] && CASE_API_KEY="$SHARED_API_KEY"
      ;;
    both)
      [[ -z "$MESSAGING_AGENT_URL" ]] && MESSAGING_AGENT_URL="$SHARED_AGENT_URL"
      [[ -z "$MESSAGING_API_KEY" ]] && MESSAGING_API_KEY="$SHARED_API_KEY"
      [[ -z "$CASE_AGENT_URL" ]] && CASE_AGENT_URL="$SHARED_AGENT_URL"
      [[ -z "$CASE_API_KEY" ]] && CASE_API_KEY="$SHARED_API_KEY"
      CONFIGURE_LEGACY=1
      ;;
  esac
fi

[[ -n "$MESSAGING_AGENT_URL" ]] && MESSAGING_AGENT_URL="$(normalize_agent_url "$MESSAGING_AGENT_URL")"
[[ -n "$CASE_AGENT_URL" ]] && CASE_AGENT_URL="$(normalize_agent_url "$CASE_AGENT_URL")"

if [[ -n "$MESSAGING_AGENT_URL" || -n "$MESSAGING_API_KEY" ]]; then
  [[ -n "$MESSAGING_AGENT_URL" && -n "$MESSAGING_API_KEY" ]] || \
    die "Both messaging agent URL and API key are required together"
fi
if [[ -n "$CASE_AGENT_URL" || -n "$CASE_API_KEY" ]]; then
  [[ -n "$CASE_AGENT_URL" && -n "$CASE_API_KEY" ]] || \
    die "Both case agent URL and API key are required together"
fi

if [[ -z "$MESSAGING_AGENT_URL" && -z "$CASE_AGENT_URL" ]]; then
  die "Pass --for messaging|case|both with --agent-url/--api-key, and/or explicit messaging/case credential pairs"
fi

log "Target org: $ORG"
[[ -n "$INSTALL_FOR" ]] && log "Install for:  $INSTALL_FOR"
[[ -n "$MESSAGING_AGENT_URL" ]] && log "Messaging agent: $MESSAGING_AGENT_URL"
[[ -n "$CASE_AGENT_URL" ]] && log "Case agent:      $CASE_AGENT_URL"

# Wire Case Quick Action onto layouts/flexipages when installing for email.
if [[ "$SKIP_CASE_PAGE" -eq 0 ]]; then
  if [[ "$INSTALL_FOR" == "case" || "$INSTALL_FOR" == "both" || -n "$CASE_AGENT_URL" ]]; then
    INCLUDE_CASE_PAGE=1
  fi
fi

if [[ "$ACTIVATE_CASE_PAGE" -eq 1 ]]; then
  [[ "$SKIP_CASE_PAGE" -eq 0 ]] || \
    die "--activate-case-page / --case-page conflicts with --skip-case-page"
  # Activation needs the Case Quick Action + page metadata in the org.
  INCLUDE_CASE_PAGE=1
  validate_case_page_name "$CASE_PAGE"
fi

if [[ "$INCLUDE_CASE_PAGE" -eq 1 ]]; then
  log "Case page wiring: enabled (Quick Action + layouts + Lightning pages)"
  if [[ "$ACTIVATE_CASE_PAGE" -eq 1 ]]; then
    log "Case page activation: $CASE_PAGE (org default View)"
  else
    log "Case page activation: skipped (pass --activate-case-page or --case-page <Name>)"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run — no deploy, permset, or Connect API calls"
fi

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
    return
  fi

  local -a source_dirs=(
    force-app/main/default/lwc/apgGenerateReply
    force-app/main/default/lwc/apgGenerateCaseReply
    force-app/main/default/classes
    force-app/main/default/namedCredentials
    force-app/main/default/externalCredentials
    force-app/main/default/permissionsets
    force-app/main/default/remoteSiteSettings
  )

  if [[ "$INCLUDE_CASE_PAGE" -eq 1 ]]; then
    log "Deploying component stack + Case email Quick Action / page wiring"
    source_dirs+=(
      force-app/main/default/lwc/apgGenerateReplyAction
      force-app/main/default/quickActions
      force-app/main/default/layouts
      force-app/main/default/flexipages
    )
    if [[ "$ACTIVATE_CASE_PAGE" -eq 1 ]]; then
      if [[ "$DRY_RUN" -eq 0 ]]; then
        write_case_view_override "$CASE_PAGE"
      fi
      source_dirs+=(force-app/main/default/objects/Case)
    fi
  else
    log "Deploying component stack (LWC, Apex, credentials, permset, remote site)"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'sf project deploy start -o %s' "$ORG"
    local d
    for d in "${source_dirs[@]}"; do
      printf ' --source-dir %s' "$d"
    done
    printf '\n'
    return
  fi

  local -a deploy_args=(-o "$ORG")
  for d in "${source_dirs[@]}"; do
    deploy_args+=(--source-dir "$d")
  done
  (cd "$ROOT" && sf project deploy start "${deploy_args[@]}")
}

# When credentials-only (--skip-deploy) but installing for case, still wire the Case page
# unless --skip-case-page was passed.
deploy_case_page_wiring() {
  if [[ "$INCLUDE_CASE_PAGE" -eq 0 ]]; then
    return
  fi
  if [[ "$SKIP_DEPLOY" -eq 0 ]]; then
    # Already included in deploy_stack.
    return
  fi

  log "Deploying Case Quick Action / layout / Lightning page wiring (--skip-deploy but case install)"
  local -a source_dirs=(
    force-app/main/default/lwc/apgGenerateReplyAction
    force-app/main/default/quickActions
    force-app/main/default/layouts
    force-app/main/default/flexipages
  )
  if [[ "$ACTIVATE_CASE_PAGE" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      write_case_view_override "$CASE_PAGE"
    fi
    source_dirs+=(force-app/main/default/objects/Case)
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'sf project deploy start -o %s' "$ORG"
    local d
    for d in "${source_dirs[@]}"; do
      printf ' --source-dir %s' "$d"
    done
    printf '\n'
    return
  fi

  local -a deploy_args=(-o "$ORG")
  local d
  for d in "${source_dirs[@]}"; do
    deploy_args+=(--source-dir "$d")
  done
  (cd "$ROOT" && sf project deploy start "${deploy_args[@]}")
}

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

is_sf_error_response() {
  printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if isinstance(d,list) else 1)"
}

ensure_custom_header() {
  local external_cred="$1"
  local master_label="$2"
  log "Ensuring External Credential custom header on ${external_cred}"
  local current desired resp
  current="$(connect_request GET "/named-credentials/external-credentials/${external_cred}")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  desired="$(EXTERNAL_CRED="$external_cred" PRINCIPAL="$PRINCIPAL" HEADER_NAME="$HEADER_NAME" CRED_PARAM="$CRED_PARAM" MASTER_LABEL="$master_label" CURRENT="$current" python3 - <<'PY'
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
    "masterLabel": current.get("masterLabel") or os.environ["MASTER_LABEL"],
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

  resp="$(connect_request PUT "/named-credentials/external-credentials/${external_cred}" "$desired")"
  if is_sf_error_response "$resp"; then
    die "Failed to update External Credential headers for ${external_cred}: $resp"
  fi
}

set_named_credential_url() {
  local named_cred="$1"
  local external_cred="$2"
  local agent_url="$3"
  local master_label="$4"
  log "Setting Named Credential URL on ${named_cred}"
  local current body resp
  current="$(connect_request GET "/named-credentials/named-credential-setup/${named_cred}")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  body="$(CURRENT="$current" AGENT_URL="$agent_url" NAMED_CRED="$named_cred" EXTERNAL_CRED="$external_cred" MASTER_LABEL="$master_label" python3 - <<'PY'
import json, os
current = json.loads(os.environ["CURRENT"])
opts = current.get("calloutOptions") or {}
# calloutStatus is returned by GET but rejected on PUT (Unrecognized field).
body = {
    "calloutUrl": os.environ["AGENT_URL"],
    "developerName": os.environ["NAMED_CRED"],
    "masterLabel": current.get("masterLabel") or os.environ["MASTER_LABEL"],
    "type": current.get("type") or "SecuredEndpoint",
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

  resp="$(connect_request PUT "/named-credentials/named-credential-setup/${named_cred}" "$body")"
  if is_sf_error_response "$resp"; then
    die "Failed to set Named Credential URL for ${named_cred}: $resp"
  fi
}

inject_api_key() {
  local external_cred="$1"
  local api_key="$2"
  log "Injecting API key into ${external_cred} principal (${CRED_PARAM})"
  local body resp
  body="$(API_KEY="$api_key" EXTERNAL_CRED="$external_cred" PRINCIPAL="$PRINCIPAL" CRED_PARAM="$CRED_PARAM" python3 - <<'PY'
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
    log "POST failed for ${external_cred} (likely already exists); updating via PATCH"
    resp="$(connect_request PATCH "/named-credentials/credential/" "$body")"
  fi
  if is_sf_error_response "$resp"; then
    die "Failed to inject API key for ${external_cred}: $resp"
  fi
}

configure_agent_credential() {
  local named_cred="$1"
  local external_cred="$2"
  local agent_url="$3"
  local api_key="$4"
  local master_label="$5"

  ensure_custom_header "$external_cred" "$master_label"
  set_named_credential_url "$named_cred" "$external_cred" "$agent_url" "$master_label"
  inject_api_key "$external_cred" "$api_key"
}

update_remote_site() {
  local agent_url="$1"
  [[ -n "$agent_url" ]] || return 0
  log "Updating Remote Site Setting URL (optional stub)"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/remoteSiteSettings"
  cat >"$tmp/remoteSiteSettings/Apologist_Agent.remoteSite-meta.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <disableProtocolSecurity>false</disableProtocolSecurity>
    <isActive>true</isActive>
    <url>${agent_url}</url>
    <description>Fallback remote site for Apologist Agent API callouts. Prefer Named Credentials.</description>
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
deploy_case_page_wiring
assign_permset

if [[ -n "$MESSAGING_AGENT_URL" ]]; then
  configure_agent_credential \
    "Apologist_Agent_Messaging" "Apologist_Agent_Messaging" \
    "$MESSAGING_AGENT_URL" "$MESSAGING_API_KEY" "Apologist Agent Messaging"
fi

if [[ -n "$CASE_AGENT_URL" ]]; then
  configure_agent_credential \
    "Apologist_Agent_Case" "Apologist_Agent_Case" \
    "$CASE_AGENT_URL" "$CASE_API_KEY" "Apologist Agent Case"
fi

# Keep legacy Apologist_Agent in sync when --for both (or default shared both).
if [[ "$CONFIGURE_LEGACY" -eq 1 && -n "$SHARED_AGENT_URL" ]]; then
  configure_agent_credential \
    "Apologist_Agent" "Apologist_Agent" \
    "$SHARED_AGENT_URL" "$SHARED_API_KEY" "Apologist Agent"
fi

update_remote_site "${SHARED_AGENT_URL:-${MESSAGING_AGENT_URL:-$CASE_AGENT_URL}}"

FINISH_CASE=""
if [[ "$INCLUDE_CASE_PAGE" -eq 1 ]]; then
  if [[ "$ACTIVATE_CASE_PAGE" -eq 1 ]]; then
    FINISH_CASE=$(cat <<CASEEOF

Case (email) page wiring:
  - Quick Action Case.Apologist_Generate_Draft_Reply deployed
  - ${CASE_PAGE} activated as org default Case View (Desktop + Phone)
  - Highlights panel Dynamic Actions include Generate Draft Reply + Send Email
  Hard-refresh a Case — both actions should appear in the top action bar.
  (LWC actions cannot be dragged onto the classic Quick Action / feed list.)
CASEEOF
)
  else
    FINISH_CASE=$(cat <<'CASEEOF'

Case (email) page wiring:
  - Quick Action Case.Apologist_Generate_Draft_Reply deployed
  - Added to Case layout Mobile & Lightning Experience Actions
  - Packaged Lightning pages updated (not set as org default)
  To take over Case View, re-run with --activate-case-page or
  --case-page <FlexiPageDeveloperName>, or activate in App Builder.
  (LWC actions cannot be dragged onto the classic Quick Action / feed list.)
CASEEOF
)
  fi
fi

cat <<EOF

Install finished for org: $ORG
$([ -n "$INSTALL_FOR" ] && echo "Configured for: $INSTALL_FOR" || true)

Defaults:
  Messaging Session pages → Named Credential Apologist_Agent_Messaging
  Case pages              → Named Credential Apologist_Agent_Case
${FINISH_CASE}
Per-instance Agent:
  Create another Named Credential in Setup (URL + API key), grant the
  Apologist Agent Callout permission set access to its principal, then set
  App Builder → Apologist Generate Reply → Named Credential to that API name.

Next:
  Messaging: Edit Messaging Session Lightning page → add Apologist Generate Reply if needed
  Case:      Hard-refresh a Case record and use Generate Draft Reply in the highlights bar

EOF

# apg-salesforce-component

Salesforce Lightning Web Component that drafts Service Cloud (Enhanced Messaging) replies using the [Apologist Agent API](https://github.com/apologist-project/apg-agent), then places the text in the conversation composer for a human to review and send.

The draft is **never** auto-submitted.

| Surface | Name |
|---------|------|
| App Builder component | **Apologist Generate Reply** |
| LWC API name | `apgGenerateReply` |
| Apex | `ApologistAgentService`, `ApologistConversationContext` |
| Callout | Named Credential `Apologist_Agent` |

---

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`) authenticated to the target org
- `curl` and `python3` (used by the install script)
- A Salesforce org with **Messaging** / Enhanced Messaging (**Messaging Session** records)
- A Lightning **console** app (e.g. Service Console) with Omni-Channel so agents can accept messaging work
- An Apologist agent with the **`api`** capability and an API key
- Agent base URL (origin only), e.g. `https://your-agent.example.com`

You will need from Apologist:

| Value | Example | Notes |
|-------|---------|--------|
| Agent **origin** | `https://my-agent.example.com` | No `/api/v1` path |
| API key | `…` | Agent must have `api` enabled |

---

## Install (recommended script)

[`scripts/install.sh`](scripts/install.sh) deploys the component stack and configures the Named Credential via the Salesforce CLI and Named Credentials Connect API.

### What it automates

| Step | Automated? |
|------|------------|
| Deploy LWC, Apex, Named/External Credential stubs, permission set, remote site | Yes |
| Assign **Apologist Agent Callout** permission set | Yes |
| Set Named Credential callout URL | Yes |
| Ensure External Credential custom header `x-api-key` | Yes |
| Inject Agent API key into principal `ApiKey` | Yes |
| Messaging / Omni-Channel / Experience site setup | No (org prerequisites) |
| Place LWC on Messaging Session Lightning page | No (App Builder; see below) |

### Quick start

```bash
git clone https://github.com/apologist-project/apg-salesforce-component.git
cd apg-salesforce-component

sf org login web -a apg-sf

./scripts/install.sh \
  --org apg-sf \
  --agent-url https://your-agent.example.com \
  --api-key "$APOLOGIST_API_KEY"
```

Equivalent environment variables:

| Variable | Flag |
|----------|------|
| `SF_TARGET_ORG` | `--org` |
| `APOLOGIST_AGENT_URL` | `--agent-url` |
| `APOLOGIST_API_KEY` | `--api-key` |
| `SF_API_VERSION` | *(default `67.0`)* |

### Script options

```text
./scripts/install.sh --help

Required:
  --org, -o           Salesforce org alias or username
  --agent-url         Agent origin only (https://host, no /api/v1)
  --api-key           Agent API key (or set APOLOGIST_API_KEY)

Optional:
  --assign-user       Username for the callout permission set
                      (default: authenticated org user)
  --skip-deploy       Configure credentials only (metadata already deployed)
  --skip-permset      Skip permission set assignment
  --full-project      Deploy entire force-app (default: component stack only)
  --dry-run           Print actions without deploying or calling APIs
```

Examples:

```bash
# Preview without changing the org
./scripts/install.sh --org apg-sf \
  --agent-url https://your-agent.example.com \
  --api-key "$APOLOGIST_API_KEY" \
  --dry-run

# Rotate API key / URL only
./scripts/install.sh --org apg-sf \
  --agent-url https://your-agent.example.com \
  --api-key "$APOLOGIST_API_KEY" \
  --skip-deploy --skip-permset
```

The script strips a trailing `/api/v1` from `--agent-url` if present. Secrets are passed to the Connect API in memory and are not written to the repo.

### After the script

1. Open a **Messaging Session** record → **Edit Page**.
2. Add **Apologist Generate Reply** (keep **Enhanced Conversation** on the page).
3. Set [configurable parameters](#configurable-parameters) as needed.
4. **Save** and **Activate**.
5. Accept an **Active** messaging session in Omni-Channel and click **Generate Draft Reply**.

---

## Install (manual)

Use this if you prefer Setup UI steps instead of `scripts/install.sh`.

### 1. Authenticate

```bash
sf org login web -a apg-sf
```

### 2. Deploy metadata

Deploy the component stack:

```bash
sf project deploy start -o apg-sf \
  --source-dir force-app/main/default/lwc/apgGenerateReply \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/namedCredentials \
  --source-dir force-app/main/default/externalCredentials \
  --source-dir force-app/main/default/permissionsets \
  --source-dir force-app/main/default/remoteSiteSettings
```

Or the full project:

```bash
sf project deploy start -o apg-sf
```

Optional scratch org:

```bash
sf org create scratch -f config/project-scratch-def.json -a apg-sf-scratch
sf project deploy start -o apg-sf-scratch
```

### 3. Configure the Agent API (Named Credential)

Callouts use `callout:Apologist_Agent/api/v1/chat/completions`. Secrets stay in Salesforce — not in the LWC.

Metadata ships with placeholder URL `https://YOUR-AGENT-DOMAIN.example`. Set the real origin and API key in Setup after deploy (or use the install script).

#### A. External Credential (API key)

1. **Setup** → search **Named Credentials** → open **External Credentials**.
2. Open **Apologist Agent** (`Apologist_Agent`).
3. Confirm protocol is **Custom** and principal **ApologistAgentPrincipal** exists.
4. Open **ApologistAgentPrincipal** → **Add** (or edit) an authentication parameter:
   - **Name:** `ApiKey`
   - **Value:** your Agent API key
5. On the External Credential, **Custom Headers** → **New**:
   - **Name:** `x-api-key`
   - **Value:** `{!$Credential.Apologist_Agent.ApiKey}`

#### B. Named Credential (agent URL)

1. **Setup** → **Named Credentials** → **Apologist Agent**.
2. Set **URL** to your agent **origin only** (no path), e.g. `https://your-agent.example.com`.
3. Confirm:
   - **External Credential:** `Apologist_Agent`
   - **Generate Authorization Header:** off
   - **Allow Formulas in HTTP Header:** on (required for the merge field above)
4. Save.

If you also use the optional **Remote Site Setting** stub, update its URL to the same origin (Named Credentials do not require a matching remote site).

#### C. Permission set

Assign **Apologist Agent Callout** to every user who will generate drafts:

```bash
sf org assign permset -n Apologist_Agent_Callout -o apg-sf
```

Or: **Setup** → **Users** → user → **Permission Set Assignments** → add **Apologist Agent Callout**.

### 4. Add the component to the Messaging Session page

Same steps as [After the script](#after-the-script).

### 5. Verify

1. Accept an inbound messaging session in Omni-Channel so the session is **Active** and owned by you.
2. Open the Messaging Session with Enhanced Conversation visible.
3. Click **Generate Draft Reply**.
4. Confirm a draft appears in the component and in the conversation reply box.
5. Edit if needed and send manually — this component does not send.

---

## Configurable parameters

Set these in Lightning App Builder by selecting **Apologist Generate Reply** on the Messaging Session page. Values are per page assignment (white-label branding is done here; the App Builder list name stays **Apologist Generate Reply**).

| App Builder label | API property | Type | Default | Description |
|-------------------|--------------|------|---------|-------------|
| **Title** | `cardTitle` | String | `Apologist Agent` | Card header title shown to agents. |
| **Description** | `cardDescription` | String | `Generate a draft reply from the Apologist Agent API.` | Short help text under the title. |
| **Icon name** | `cardIcon` | String | `standard:sparkles` | SLDS icon for the card header. |
| **Icon background color** | `iconBackgroundColor` | String | `#7137ff` | Background color for the card header icon. |
| **Button color** | `buttonColor` | String | `#7137ff` | Background/border color for **Generate Draft Reply**. |
| **Past messages to include** | `messageLimit` | Integer | *(blank)* | How much transcript to send to the Agent API. |

Button label (**Generate Draft Reply**) and the draft field label (**Generated Draft Reply**) are fixed in the component.

### Title and description

Use these for customer branding (e.g. product or program name). Leave blank to fall back to the defaults above.

Existing Lightning pages keep whatever Title/Description were saved in App Builder; changing source defaults only affects new placements (or instances that still use the blank/default fallback).

### Icon name

Use Salesforce Lightning Design System icons in **`category:name`** form:

- Examples: `standard:sparkles`, `standard:robot`, `utility:chat`, `utility:einstein`
- Catalog: [Lightning Design System — Icons](https://www.lightningdesignsystem.com/icons/)

Invalid names may show a blank or broken icon; fix the string in App Builder and save the page.

Heroicons / custom SVGs are not supported via this property. For a custom mark, upload a Static Resource and extend the LWC header (not included out of the box).

### Icon background color

CSS color for the header icon tile (hex recommended, e.g. `#7137ff`). Default is `#7137ff`. If you change **Icon name**, you may want a matching background for that icon.

Applied via SLDS icon styling hooks (`--slds-c-icon-color-background`).

### Button color

CSS color for the **Generate Draft Reply** brand button (hex recommended, e.g. `#7137ff`). Default is `#7137ff`; blank falls back to that same default.

Applied via SLDS button brand styling hooks (`--slds-c-button-brand-color-background` / border, including hover).

### Past messages to include

Controls how much of the Messaging Session transcript is sent to `POST /api/v1/chat/completions`:

| Value | Behavior |
|-------|----------|
| Blank / unset | Entire conversation |
| Positive integer **N** | **N** most recent messages (prompt still chronological) |
| Zero or negative | Treated as entire conversation |

Larger transcripts use more tokens and may hit agent or platform limits; use **N** when sessions run long.

---

## Runtime behavior

1. Agent clicks **Generate Draft Reply**.
2. Apex loads conversation entries (honoring `messageLimit`), then calls `POST /api/v1/chat/completions` with `stream: false` via the Named Credential.
3. The LWC shows the draft under **Generated Draft Reply**.
4. If the session can accept composer updates, the LWC calls Conversation Toolkit [`setAgentInput`](https://developer.salesforce.com/docs/atlas.en-us.api_console.meta/api_console/sforce_api_console_lightning_setagentinput_lwc.htm) to fill the reply box (**does not** send).
5. The human reviews, edits if needed, and sends manually.

### Requirements for filling the reply box

- Messaging Session status **Active** (accepted from Omni-Channel; not Waiting / queue-owned only)
- Running user owns / can work the session
- **Enhanced Conversation** on the Lightning page and open in the console
- Console app with Conversation Toolkit support

If generation succeeds but the composer cannot be updated, the draft still appears in the component and a warning toast explains why.

---

## Project layout

```text
force-app/main/default/
  lwc/apgGenerateReply/           # Record-page UI + App Builder properties
  classes/ApologistAgentService*  # Named Credential callout + tests
  classes/ApologistConversationContext*
  namedCredentials/Apologist_Agent*
  externalCredentials/Apologist_Agent*
  permissionsets/Apologist_Agent_Callout*
  remoteSiteSettings/Apologist_Agent*   # Optional fallback stub
scripts/install.sh                # Deploy + Named Credential configuration
```

---

## Tests

```bash
sf apex run test --tests ApologistAgentServiceTest --result-format human -o apg-sf
```

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Callout / credential errors | Named Credential URL wrong; missing `ApiKey` or `x-api-key` header; permission set not assigned |
| Install script API key failure | Org auth expired (`sf org login web`); user lacks access to manage Named Credentials |
| Empty or failed draft | Agent host down; API key lacks `api`; agent error — check Apex debug logs |
| Draft in component but not in reply box | Session not **Active**; Enhanced Conversation missing/closed; not in a supported console |
| Icon missing | `cardIcon` not valid `category:name` SLDS icon |
| Old title/icon after deploy | Page still has previous App Builder property values — edit the component properties or re-add the component |


See [`AGENTS.md`](AGENTS.md) for agent-oriented conventions.

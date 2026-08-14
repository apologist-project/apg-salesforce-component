# apg-salesforce-component

Salesforce Lightning Web Component that drafts Service Cloud replies using the [Apologist Agent API](https://github.com/apologist-project/apg-agent) for:

- **Messaging Session** (Enhanced Messaging) — fills the conversation reply box via `setAgentInput`
- **Case** (email) — builds context from the Case `EmailMessage` thread and opens **Send Email** with the draft pre-filled

The draft is **never** auto-submitted.

| Surface | Name |
|---------|------|
| App Builder component | **Apologist Generate Reply** |
| LWC API name | `apgGenerateReply` |
| Apex | `ApologistAgentService`, `ApologistConversationContext` |
| Callout | Named Credentials `Apologist_Agent_Messaging` / `Apologist_Agent_Case` (per-instance override supported) |

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
| Place LWC on Messaging Session / Case Lightning pages | No (App Builder; see below) |

### Quick start

```bash
git clone https://github.com/apologist-project/apg-salesforce-component.git
cd apg-salesforce-component

sf org login web -a apg-sf

# Same Agent for both contexts (+ legacy)
./scripts/install.sh \
  --org apg-sf \
  --for both \
  --agent-url https://your-agent.example.com \
  --api-key "$APOLOGIST_API_KEY"

# Messaging (chat) Agent only
./scripts/install.sh \
  --org apg-sf \
  --for messaging \
  --agent-url https://chat-agent.example.com \
  --api-key "$CHAT_KEY"

# Case (email) Agent only
./scripts/install.sh \
  --org apg-sf \
  --for case \
  --agent-url https://email-agent.example.com \
  --api-key "$EMAIL_KEY"

# Or set each Agent explicitly (no --for)
./scripts/install.sh \
  --org apg-sf \
  --messaging-agent-url https://chat-agent.example.com \
  --messaging-api-key "$CHAT_KEY" \
  --case-agent-url https://email-agent.example.com \
  --case-api-key "$EMAIL_KEY"
```

Equivalent environment variables:

| Variable | Flag |
|----------|------|
| `SF_TARGET_ORG` | `--org` |
| `APOLOGIST_INSTALL_FOR` | `--for` (`messaging` / `case` / `both`) |
| `APOLOGIST_AGENT_URL` / `APOLOGIST_API_KEY` | `--agent-url` / `--api-key` (scoped by `--for`) |
| `APOLOGIST_MESSAGING_AGENT_URL` / `APOLOGIST_MESSAGING_API_KEY` | `--messaging-agent-url` / `--messaging-api-key` |
| `APOLOGIST_CASE_AGENT_URL` / `APOLOGIST_CASE_API_KEY` | `--case-agent-url` / `--case-api-key` |
| `SF_API_VERSION` | *(default `67.0`)* |

### Script options

```text
./scripts/install.sh --help

Org / deploy:
  --org, -o
  --skip-deploy, --skip-permset, --full-project, --dry-run, --assign-user

Context:
  --for messaging|case|both   Scope --agent-url/--api-key (aliases: chat, email, all)

Credentials:
  --agent-url / --api-key                         Agent pair (used with --for)
  --messaging-agent-url / --messaging-api-key     Messaging Named Credential
  --case-agent-url / --case-api-key               Case Named Credential
```

Examples:

```bash
# Preview messaging-only install
./scripts/install.sh --org apg-sf --for messaging \
  --agent-url https://chat-agent.example.com \
  --api-key "$CHAT_KEY" \
  --dry-run

# Rotate Case agent only
./scripts/install.sh --org apg-sf --for case \
  --agent-url https://email-agent.example.com \
  --api-key "$EMAIL_KEY" \
  --skip-deploy --skip-permset
```

The script strips a trailing `/api/v1` from agent URLs if present. Secrets are passed to the Connect API in memory and are not written to the repo.

**API keys are never App Builder properties.** Each Agent’s URL + key live in a Named Credential. For a different Agent on a specific page, create another Named Credential in Setup and set the component’s **Named Credential** property to that API name.

### After the script

Add the component on each surface you need:

**Messaging Session**

1. Open a **Messaging Session** record → **Edit Page**.
2. Add **Apologist Generate Reply** (keep **Enhanced Conversation** on the page).
3. Set [configurable parameters](#configurable-parameters) as needed.
4. **Save** and **Activate**.
5. Accept an **Active** messaging session in Omni-Channel and click **Generate Draft Reply**.

**Case (email)**

1. Open a **Case** record → **Edit Page** (or Setup → Object Manager → Case → Lightning Record Pages).
2. Add **Apologist Generate Reply**.
3. Set [configurable parameters](#configurable-parameters) as needed.
4. **Save** and **Activate**.
5. Open a Case with related emails, click **Generate Draft Reply** — the draft appears in the widget and **Send Email** opens with the body pre-filled.
6. Ensure **HtmlBody** / **Subject** are not read-only on the Case **Send Email** quick action layout (otherwise defaults may not apply).

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

Callouts use `callout:<NamedCredential>/api/v1/chat/completions`. Secrets stay in Salesforce — not in the LWC.

| Context | Default Named Credential | External Credential |
|---------|--------------------------|---------------------|
| Messaging Session | `Apologist_Agent_Messaging` | `Apologist_Agent_Messaging` |
| Case email | `Apologist_Agent_Case` | `Apologist_Agent_Case` |
| Legacy / override | `Apologist_Agent` | `Apologist_Agent` |

Metadata ships with placeholder URLs. Set the real origin and API key in Setup after deploy (or use the install script).

For **each** Agent credential pair:

#### A. External Credential (API key)

1. **Setup** → **Named Credentials** → **External Credentials**.
2. Open the External Credential (e.g. **Apologist Agent Messaging**).
3. Confirm protocol is **Custom** and principal **ApologistAgentPrincipal** exists.
4. Open **ApologistAgentPrincipal** → **Add** (or edit) an authentication parameter:
   - **Name:** `ApiKey`
   - **Value:** that Agent’s API key
5. **Custom Headers** → **New**:
   - **Name:** `x-api-key`
   - **Value:** `{!$Credential.<ExternalCredentialApiName>.ApiKey}`  
     (e.g. `{!$Credential.Apologist_Agent_Messaging.ApiKey}`)

#### B. Named Credential (agent URL)

1. **Setup** → **Named Credentials** → matching Named Credential.
2. Set **URL** to that agent **origin only** (no path).
3. Confirm:
   - **External Credential:** matching External Credential
   - **Generate Authorization Header:** off
   - **Allow Formulas in HTTP Header:** on
4. Save.

Repeat for Messaging and Case (and any extra Named Credentials you create for other widget instances). Grant the **Apologist Agent Callout** permission set access to each new External Credential principal.

If you also use the optional **Remote Site Setting** stub, update its URL as needed (Named Credentials do not require a matching remote site).

#### C. Permission set

Assign **Apologist Agent Callout** to every user who will generate drafts:

```bash
sf org assign permset -n Apologist_Agent_Callout -o apg-sf
```

Or: **Setup** → **Users** → user → **Permission Set Assignments** → add **Apologist Agent Callout**.

### 4. Add the component to Messaging Session and/or Case pages

Same steps as [After the script](#after-the-script).

### 5. Verify

**Messaging**

1. Accept an inbound messaging session in Omni-Channel so the session is **Active** and owned by you.
2. Open the Messaging Session with Enhanced Conversation visible.
3. Click **Generate Draft Reply**.
4. Confirm a draft appears in the component and in the conversation reply box.
5. Edit if needed and send manually — this component does not send.

**Case email**

1. Open a Case that has related **EmailMessage** rows (or at least a Description).
2. Click **Generate Draft Reply**.
3. Confirm the draft appears in the widget and Send Email opens with the body pre-filled.
4. Review and send manually — this component does not send.

---

## Configurable parameters

Set these in Lightning App Builder by selecting **Apologist Generate Reply** on a Messaging Session or Case page. Values are per page assignment (white-label branding is done here; the App Builder list name stays **Apologist Generate Reply**).

| App Builder label | API property | Type | Default | Description |
|-------------------|--------------|------|---------|-------------|
| **Title** | `cardTitle` | String | `Apologist Agent` | Card header title shown to agents. |
| **Description** | `cardDescription` | String | `Generate a draft reply from the Apologist Agent API.` | Short help text under the title. |
| **Icon name** | `cardIcon` | String | `standard:sparkles` | SLDS icon for the card header. |
| **Icon background color** | `iconBackgroundColor` | String | `#7137ff` | Background color for the card header icon. |
| **Button color** | `buttonColor` | String | `#7137ff` | Background/border color for **Generate Draft Reply**. |
| **Past messages to include** | `messageLimit` | Integer | *(blank)* | How much Messaging transcript or Case email thread to send to the Agent API. |
| **Named Credential** | `namedCredential` | String | *(blank)* | Named Credential API name for this instance’s Agent. Blank → `Apologist_Agent_Messaging` or `Apologist_Agent_Case` by page type. |

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

### Named Credential (per-instance Agent)

Each Agent has its own URL + API key, stored in a Salesforce Named Credential (not in the LWC).

- Leave **Named Credential** blank to use the context default (`Apologist_Agent_Messaging` or `Apologist_Agent_Case`).
- To point one page placement at a different Agent: create a Named Credential + External Credential in Setup, grant principal access on **Apologist Agent Callout**, then set this property to the Named Credential’s API name.

### Past messages to include

Controls how much context is sent to `POST /api/v1/chat/completions`:

| Value | Behavior |
|-------|----------|
| Blank / unset | Entire Messaging conversation or Case email thread |
| Positive integer **N** | **N** most recent messages (prompt still chronological) |
| Zero or negative | Treated as entire thread |

Larger transcripts use more tokens and may hit agent or platform limits; use **N** when sessions run long.

---

## Runtime behavior

1. Agent clicks **Generate Draft Reply**.
2. Apex detects **Messaging Session** vs **Case**:
   - **Messaging:** loads transcript via Connect REST conversation entries (Enhanced Messaging; SOQL `ConversationEntry.Message` is blank off-core)
   - **Case:** loads related `EmailMessage` rows (plus Case subject/description preamble)
3. Apex honors `messageLimit`, then calls `POST /api/v1/chat/completions` with `stream: false` via the Named Credential.
4. The LWC shows the draft under **Generated Draft Reply**.
5. Composer step (**does not** send):
   - **Messaging (Active):** Conversation Toolkit [`setAgentInput`](https://developer.salesforce.com/docs/atlas.en-us.api_console.meta/api_console/sforce_api_console_lightning_setagentinput_lwc.htm)
   - **Case:** navigates to **Case.SendEmail** (fallback `Global.SendEmail`) with `HtmlBody` / `Subject` pre-filled via `encodeDefaultFieldValues`
6. The human reviews, edits if needed, and sends manually.

### Requirements for Messaging reply box fill

- Messaging Session status **Active** (accepted from Omni-Channel; not Waiting / queue-owned only)
- Running user owns / can work the session
- **Enhanced Conversation** on the Lightning page and open in the console
- Console app with Conversation Toolkit support

### Requirements for Case email pre-fill

- Case has related emails and/or a Description
- Case **Send Email** quick action available on the page/layout
- **HtmlBody** and **Subject** not marked read-only on that action’s layout

If generation succeeds but the composer cannot be updated/opened, the draft still appears in the component.

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
| Callout / credential errors | Named Credential URL wrong; missing `ApiKey` or `x-api-key` header; permission set not assigned; wrong **Named Credential** property |
| Wrong Agent answered | Messaging vs Case defaults differ; check App Builder **Named Credential** and which NC URL/key is configured |
| Install script API key failure | Org auth expired (`sf org login web`); user lacks access to manage Named Credentials |
| Empty or failed draft | Agent host down; API key lacks `api`; agent error — check Apex debug logs |
| Draft ignores the chat | Connect transcript failed; check Apex debug for Connect `/connect/conversation/.../entries` errors |
| `INVALID_SESSION_ID` on Connect | Lightning sessions are not API-enabled; the component uses VF page `ApologistApiSession` for a REST-capable token — ensure that page is deployed and the **Apologist Agent Callout** permission set is assigned |
| Draft in component but not in reply box | Session not **Active**; Enhanced Conversation missing/closed; not in a supported console |
| Case draft OK but email fields empty | HtmlBody/Subject read-only on Send Email action layout; or Case.SendEmail missing — try adding the Email action |
| Case “no context” error | No related EmailMessage rows and empty Case Description |
| Component missing from Case App Builder | Redeploy LWC meta (Case must be listed in targets); hard-refresh App Builder |
| Icon missing | `cardIcon` not valid `category:name` SLDS icon |
| Old title/icon after deploy | Page still has previous App Builder property values — edit the component properties or re-add the component |


See [`AGENTS.md`](AGENTS.md) for agent-oriented conventions.

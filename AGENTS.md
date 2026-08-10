# AGENTS.md — apg-salesforce-component

Salesforce DX project: Lightning Web Component + Apex that drafts Enhanced Messaging replies via the Apologist **Agent API** (not the beacon embed).

## Stack

- Salesforce DX (`sfdx-project.json`, `force-app/`)
- LWC: `apgGenerateReply` on **MessagingSession** record pages
- Apex: `ApologistAgentService` (callout), `ApologistConversationContext` (transcript + limit)
- Auth: Named Credential `Apologist_Agent` + External Credential (header `x-api-key`)

## Do / don’t

| Do | Don’t |
|----|--------|
| `POST /api/v1/chat/completions` with `stream: false` | Embed `/beacon/agent*.js` for this draft flow |
| Put drafts in the composer with `setAgentInput` | Call `sendTextMessage` / auto-send |
| Keep API keys in Named / External Credentials | Put `x-api-key` in LWC or client JS |
| Honor `messageLimit` from App Builder | Hardcode a default limit when unset |

## `messageLimit`

App Builder property **Past messages to include** (`@api messageLimit`):

- **Null / empty / unset / non-positive** → entire conversation
- **Positive N** → N most recent `ConversationEntry` messages (prompt still chronological)

Passed to `ApologistAgentService.generateDraft(messagingSessionId, messageLimit)`.

## Agent API contract

- Base: Named Credential URL + `/api/v1/chat/completions`
- Auth: `x-api-key` (agent must have `api` capability)
- Prefer `response_format: { "type": "json" }` and read `choices[0].message.content`
- Spec: `apg-agent` → `public/docs/openapi.yaml`

## Local commands

```bash
sf project deploy start -o <org-alias>
sf apex run test --tests ApologistAgentServiceTest --result-format human -o <org-alias>
```

Scratch definition: `config/project-scratch-def.json` (Messaging features).

## Workspace

In `apg-workspace`, soft-link as `salesforce-component/` → `apg-salesforce-component` via `scripts/setup-links.sh`.

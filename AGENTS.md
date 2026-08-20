# AGENTS.md — apg-salesforce-component

Salesforce DX project: Lightning Web Component + Apex that drafts Service Cloud replies via the Apologist **Agent API** (not the beacon embed) for **Messaging Session** and **Case** email.

## Stack

- Salesforce DX (`sfdx-project.json`, `force-app/`)
- LWC: `apgGenerateReply` on **MessagingSession**; `apgGenerateCaseReply` on **Case** record pages; `apgGenerateReplyAction` headless **Case** Quick Action
  - Case pages must use `apgGenerateCaseReply` (not `apgGenerateReply`) — the Messaging LWC statically imports `conversationToolkitApi`, which prevents it from loading on Case
- Apex: `ApologistAgentService.generateDraftForRecord(recordId, messageLimit, namedCredential)`
- Case Quick Action metadata: `Case.Apologist_Generate_Draft_Reply` (add to Case page layout actions)
- Case View activation (opt-in): `scripts/install.sh --activate-case-page` or `--case-page <FlexiPageDeveloperName>`
- Auth (API key per Agent):
  - Default Messaging: Named Credential `Apologist_Agent_Messaging`
  - Default Case: Named Credential `Apologist_Agent_Case`
  - Optional per-instance override via App Builder `namedCredential`
  - Legacy `Apologist_Agent` still deployable for overrides / migration
- Messaging transcript: Connect REST conversation entries (+ VF `ApologistApiSession` for API session)
- Case transcript: related `EmailMessage` (+ Case subject/description preamble)

## Do / don’t

| Do | Don’t |
|----|--------|
| `POST /api/v1/chat/completions` with `stream: false` | Embed `/beacon/agent*.js` for this draft flow |
| Keep Agent URL + API key in Named / External Credentials | Put `x-api-key` in LWC or App Builder string props |
| Use separate NCs for Messaging vs Case (or per-instance override) | Assume one Agent URL for every surface |
| Messaging: `setAgentInput`; Case: open Send Email with defaults | Auto-send |
| Honor `messageLimit` from App Builder | Hardcode a default limit when unset |

## Local commands

```bash
sf project deploy start -o <org-alias>
sf apex run test --tests ApologistAgentServiceTest --result-format human -o <org-alias>
./scripts/install.sh --org <alias> --messaging-agent-url … --messaging-api-key … --case-agent-url … --case-api-key …
```

## Workspace

In `apg-workspace`, soft-link as `salesforce-component/` → `apg-salesforce-component` via `scripts/setup-links.sh`.

---
name: it-operations
description: Contoso-specific IT operations memory - runbooks, access patterns, secrets handling, and cross-system workflows for Power Apps/SharePoint ITAM, ScreenConnect, Keeper/KSM, Microsoft Graph/Intune, Freshservice, Automox, Rapid7, CrowdStrike Falcon, and endpoint troubleshooting. Use at the start of any Contoso IT task mentioning Power Apps, an asset tracker, SharePoint ITAM, a ticket, "silently diagnose", "don't touch the ticket", endpoint, device issue, patching, compliance, or secrets. Acts as the routing index - when the request squarely matches a dedicated skill (acquire-graph-token, screenconnect-remote-diagnostics, freshservice-automation-builder, freshservice-service-catalog, prepare-cab-change-ticket, ssh-access, check-autopilot-serials, analyze-vulnerability-kpis, query-crowdstrike-falcon, run-intune-maa-teams-notifier), use that skill and keep this one for shared defaults and cross-system context. Graph/z_admin tokens belong in acquire-graph-token, not here. Silent ticket diagnosis is read-only.
---

# Contoso IT Operations

## Start Here

Read the portable reference first: `references/operations-index.md` inside this skill's folder.

Then read the relevant repo runbook if it is available:

```text
C:\automox-mcp-main\docs\it-operations-memory.md
```

## Routing

- For ScreenConnect command execution, host sessions, or endpoint PowerShell, use the screenconnect-remote-diagnostics skill and read the ScreenConnect runbook.
- For retrieving a password, API key, or credential from the Keeper vault, use the retrieve-keeper-secret skill. For the KSM target-state design or replacing `env.local` wholesale, read the Keeper runbooks.
- For Graph/Intune **tokens**, z_admin, delegated Graph, Exchange as the z-account, or MAA approve/reject, use the acquire-graph-token skill first (TAP remint; do not ask for device-code or Keeper MFA). Then read the Graph/Intune runbook for what to do with access.
- For Intune, Graph, MAA, app deployment, compliance, remediation, or device management **after a token exists**, read the Graph/Intune runbook.
- For tickets, ticket IDs, service desk queues, OpenInvoice, or Enverus ticket history, use Freshservice live API first and read the Freshservice runbook.
- For Microsoft 365 tenant-setting attribution, search Purview Audit for `TeamsAdminAction` across a window that starts before the suspected change, then inspect `MicrosoftTeamsAdmin` items/details for the affected setting. If the PowerShell audit path cannot launch, use the authenticated Purview Audit UI. Treat a no-match result as strong evidence only after the search completes and unrelated Teams admin events confirm audit coverage.
- For Freshservice Workflow Automator rules, ticket automations, approval gates, incident-to-service-request conversion, Dorian/security approvals, or EUC handoffs, use the freshservice-automation-builder skill.
- For Freshservice service catalog items, request forms, categories, converting requesters to agents, or reaching classic/internal Freshservice endpoints the REST API can't (via an authenticated CDP + magic-link session), use the freshservice-service-catalog skill.
- For drafting or reviewing change requests, change tickets, CAB submissions, or change ticket content requirements (IT-CHG-STD-001), use the prepare-cab-change-ticket skill.
- For Automox devices, policies, groups, packages, patching, or compliance, use Automox MCP resources/tools and read the Automox runbook.
- For CrowdStrike Falcon hosts, alerts, Spotlight CVEs, containment/RFM status, or Falcon host groups, use the query-crowdstrike-falcon skill. That API client is read-only.
- For Rapid7 findings, read the Rapid7 runbook first; no Rapid7 API connection was verified when this skill was created.
- For Contoso Power Apps canvas work, SharePoint-backed ITAM, Power Apps Studio recovery, preview validation, or unpublished pilot saves, read `references/power-apps-canvas-studio.md` inside this skill's folder before interacting with the maker portal.
- For cross-system endpoint work, read the cross-system troubleshooting runbook.

## Core Rules

- Use live systems first when operational truth matters.
- Freshservice writes are opt-in. Create, assign, unassign, private/public notes, replies, status, and resolution all need an explicit user request ("assign this", "add a note", "reply", "take the ticket", "resolve it"). "Silently diagnose", "silent", "quietly", "don't touch the ticket", "just look", and diagnose-only asks are GET-only: read the ticket, investigate, report in chat. A ticket URL or ID is not permission to mutate it. Do not assign a ticket to Avery just because he asked you to look at it.
- For substantive Contoso IT work that investigates, changes, tests, or plans changes in production systems, ask Avery Operator for explicit approval before creating a Freshservice ticket. After that approval, create or reuse a ticket near the start, assign it to Avery Operator, and add notes as work proceeds — only when the user asked to work, own, or update the ticket, never on silent diagnosis. Include ticket ID, scope, evidence, decisions, and next steps in the chat response. Skip ticket creation for quick read-only lookups or explicitly ticketless work.
- Keep credentials, API keys, access tokens, Keeper one-time tokens, and REST secrets out of chat output and files.
- Prefer Keeper/KSM over plaintext env files.
- Treat ScreenConnect, Intune, Automox, and Graph write operations as production-impacting.
- Ask for explicit approval before remediation, command execution that changes state, rebooting, restarting services, installing/uninstalling software, registry edits, file deletion, or permission changes.
- When validating Automox device packages, never treat absence from an unpaged `list_device_packages` response as proof that a package is absent. Check `metadata.truncated` and token warnings, then page explicitly until `has_more=false` (or use the complete raw endpoint). The helper can finish upstream pagination while truncating the returned `packages[]` for response size.
- For Intune custom-compliance removal, inspect the `deviceComplianceScripts` assignment collection directly. Deleting the compliance policy does not prove its discovery script is unassigned; verify the script's live assignments before and after remediation.
- When the user says "tickets", assume Freshservice unless they explicitly name another ticketing system.
- Use the admin Microsoft Edge workspace/profile for interactive ScreenConnect host UI, not the regular `avery.operator@contoso.com` Edge workspace.
- For Contoso Word artifacts built with docx-js, pass an explicit image type to every `ImageRun` (for example, `type: "png"`). If omitted, the package can contain `.undefined` image relationships that Microsoft Word rejects. Open the finished `.docx` in Word and inspect every page before delivery.
- For Word-to-PDF verification on this Windows endpoint, the 64-bit scripting host can fail to create `Word.Application`; use `C:\Windows\SysWOW64\cscript.exe` with Word COM instead. With docx-js landscape pages, supply portrait-order width and height together with `PageOrientation.LANDSCAPE` because the library swaps the dimensions when serializing; audit for 11 x 8.5 inches before delivery.

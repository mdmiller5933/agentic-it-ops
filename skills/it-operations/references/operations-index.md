# Contoso IT Operations Index

Last reviewed: 2026-08-19

## Purpose

Use this as portable memory for new Codex chats and workspaces. Prefer detailed repo runbooks under `C:\automox-mcp-main\docs` when available.

## Repo Runbooks

- `C:\automox-mcp-main\docs\it-operations-memory.md`
- `C:\automox-mcp-main\docs\screenconnect-api-remote-diagnostics-runbook.md`
- `C:\automox-mcp-main\docs\automox-screenconnect-diagnostics-runbook.md`
- `C:\automox-mcp-main\docs\keeper-secrets-codex-setup.md`
- `C:\automox-mcp-main\docs\microsoft-graph-intune-access-runbook.md`
- `C:\automox-mcp-main\docs\freshservice-ticketing-runbook.md`
- `C:\automox-mcp-main\docs\automox-operational-runbook.md`
- `C:\automox-mcp-main\docs\rapid7-operational-runbook.md`
- `C:\automox-mcp-main\docs\cross-system-endpoint-troubleshooting-runbook.md`

## Confirmed Facts

### Local workspace fallback

- Verified 2026-08-08: if Windows blocks both the normal shell launch and the documented
  `cmd.exe` / `pwsh.exe` retry with `os error 1223`, stop retrying. For read-only local
  inspection, use an already-running in-process JavaScript runtime with `node:fs/promises`;
  use `node:child_process` only for non-mutating commands if that path still works. This
  fallback does not broaden authorization to edit files or change production systems.

### Freshservice

- "Tickets" means Freshservice unless the user explicitly says otherwise.
- Freshservice writes (create, assign, notes, replies, status, resolution) need an explicit user request. "Silently diagnose" / "don't touch the ticket" / diagnose-only is GET-only: report in chat, never assign or add notes. A ticket ID is not write permission. Verified 2026-08-17 on ticket `10287`.
- For substantive Contoso IT work that investigates, changes, tests, or plans changes in production systems, ask Avery Operator for explicit approval before creating a Freshservice ticket. After that approval, create or reuse a ticket near the start, assign it to Avery Operator, and document progress with notes — only when the user asked to work, own, or update the ticket. If the user supplies an existing ticket ID, read that ticket; do not create a new one, and do not write to it unless they asked.
- Verified 2026-07-02 on ticket `10140`: Avery Operator requester/responder ID `34002018724`; workspace `IT` (`2`); team `EUC Monitoring Team` (`34000153387`).
- Use the daily Freshservice cache first for broad historical searches, queue summaries, metrics, and expensive lookups when the cache is fresh enough.
- Use the live Freshservice API for current ticket state, latest conversations, writes, status changes, or anything the user asks to check "right now".
- To resolve a Freshservice ticket/incident, use the actual Resolution area via `PUT /api/v2/tickets/{ticket_id}` with `resolution_notes`, and set `status: 4` for Resolved. Do not use a private note unless requested.
- For native Freshservice Workflow Automator rules, approval gates, ticket routing automations, incident-to-service-request conversion, Dorian approvals, or EUC handoff flows, use the freshservice-automation-builder skill.
- Known active native automation: workflow `34000381035`, `EUC Security Review Approval Gate - Native Approval`, in IT workspace `2`. It triggers on ticket update for Incident or Service Request tickets assigned to GRC - Security and Dorian, converts to Service Request, requests Dorian approval, and routes approved/rejected tickets back to EUC without changing status.
- On 2026-06-29, live API search found 61 OpenInvoice/Open Invoice tickets out of 4,712 accessible tickets.

### Keeper

- Keeper Commander is the working secret-retrieval path. Use the retrieve-keeper-secret skill for
  any credential lookup; it carries the leak warnings and session-recovery steps.
- Verified 2026-07-31: Commander `18.0.13`, account `avery.operator@contoso.com`, SSO Cloud
  (SAML/Entra), credentials in Windows Credential Manager (not a plaintext file), Persistent Login
  ON, 1-hour idle logout.
- Standalone `ksm` CLI still not on PATH and no KSM applications exist; Keeper Secrets Manager
  remains an unbuilt target state with an unverified entitlement gate.
- `keeper get <uid> --format=json` does NOT mask and dumps secrets in cleartext. Plain
  `keeper get <uid>` masks.

### ScreenConnect

- Tenant: `https://contoso.screenconnect.com`
- RESTful API Manager extension ID: `0ff94084-d9cb-c690-de57-8eb8ee7aa1ae`
- Auth header: `CTRLAuthHeader`
- Confirmed methods: `GetSessionsByFilter`, `SendCommandToSession`
- Verified 2026-06-30: `SendCommandToSession` queues and returns no value, but command output can be obtained afterward from ScreenConnect `SessionEvent` data with RESTful API Manager `GetReport`. Query `ReportType = "SessionEvent"` for `RanCommand`/`QueuedCommand`, filter by `SessionID` plus a unique marker in `Data`, and redact before sharing output.
- Interactive host UI uses the admin Microsoft Edge workspace/profile, not the regular `avery.operator@contoso.com` workspace.

### Microsoft Graph / Intune

- Persistent Graph account: `z_admin@contoso.com`. App-only cert is the default for
  unattended Graph. Delegated z-account (`/me`, Exchange, MAA approve/reject) uses the
  acquire-graph-token skill: `graph-token.cmd`, and on `NEED_BOOTSTRAP` run
  `Invoke-DelegatedGraphTapRemint.ps1` (TAP + Playwright). Do not ask for device-code or
  Keeper MFA. Verified 2026-08-18.
- Tenant: `Contoso Energy`
- Tenant ID: `80bcfe19-ba5c-bcaf-8f4b-1dadba37a010`
- MAA approver group: `AZ-Intune-Approvers`
- MAA approver group ID: `65d7db1f-80a1-07bf-80bc-6d6298912d1b`
- Verified 2026-08-09: for legacy imported-ADMX `groupPolicyConfigurations`, a single
  `updateDefinitionValues` request that mixes `added`, `updated`, and `deletedIds` can fail with
  a generic `400` while changing nothing. Re-read before recovery, then work one assigned ring at
  a time: PATCH existing definition values and verify them; use an added-only
  `updateDefinitionValues` request and verify it; DELETE obsolete definition values individually;
  then re-read the exact settings, assignments, and MAA request IDs before proceeding. This tenant
  returns `204` for a successful definition-value PATCH even though the Graph documentation shows
  `200`. Never blindly replay the failed combined request.
- For read-only app install evidence when the Windows host blocks child-process
  launches, request the `DeviceInstallStatusByApp` export through
  `/v1.0/deviceManagement/reports/exportJobs` and parse the returned ZIP in-process.
  The exported JSON can start with a UTF-8 BOM and uses lowercase `columns` and
  `values`; `values` may already contain row objects. Strip the BOM and handle that
  shape explicitly. Prefer an in-process ZIP library over `tar` or `Expand-Archive`
  after `EPERM` or `os error 1223`.
- When creating a Windows ESP with a non-empty `selectedMobileAppIds` list, set
  `blockDeviceSetupRetryByUser=false`. Intune's onboarding service returns an opaque
  `400 BadRequest` when that selected-app configuration is combined with retry blocking
  (verified 2026-08-08). Create the profile unassigned, call `setPriority`, then assign
  it only after re-reading the stored settings. Never send MAA approval headers unless
  the user explicitly authorized an approval workflow.
- For Windows Autopilot pre-provisioned deployments, ESP quality updates do not run in
  Technician Flow; Intune honors `installQualityUpdates` in User Flow instead and Microsoft
  estimates that it adds 20-40 minutes (verified 2026-08-08). Do not use this setting to
  enforce technician patch discipline. Use a vendor/technician readiness gate, and set it
  to false when first-login speed is the requirement.
- Updating an existing `windows10EnrollmentCompletionPageConfiguration` with a one-property
  PATCH can fail `400 ModelValidationFailure`. Send a complete typed editable-settings body
  with `@odata.type`. If `blockDeviceSetupRetryByUser=true`, omit
  `allowDeviceUseOnInstallFailure`, `allowDeviceResetOnInstallFailure`, and
  `selectedMobileAppIds`; also omit server-managed identifiers, timestamps, version/type,
  and priority. Re-read the profile and assignments after the write (verified 2026-08-08).

### SharePoint Lists

- Verified 2026-08-08: the SharePoint document connector can validate a site but may not expose
  Microsoft Lists schema or rows. For live read-only list truth, use an authenticated browser on
  the exact list and same-origin SharePoint REST `GET` requests under `/_api/web/lists(...)`.
  Return only the needed metadata or aggregates, and do not use write verbs without explicit
  approval.

### SharePoint / OneDrive files shared with Avery

Verified 2026-07-27. Reading a `*-my.sharepoint.com/:x:/g/personal/<someone>/...` share link
that a colleague sent Avery:

- The persistent Graph token (`z_admin`) does NOT work for this. Its scope set has no
  `Files.*` or `Sites.*`, so `GET /shares/{shareId}/driveItem` returns 403 `accessDenied` and
  `GET /users/<owner>/drive` returns 404. Don't burn time re-trying Graph as the z-account.
- Graph Search over the tenant (the M365/SharePoint connector) does not reliably surface another
  user's personal OneDrive, and short prefixes get stemmed (searching `WKS` returns `bid`
  documents). Don't rely on search to locate a link the user already gave you.
- What works: open the share URL in a browser session already signed in as
  `avery.operator@contoso.com` (use whatever browser automation the tool has; the sandboxed
  in-app browser is NOT signed in and will stop at login.microsoftonline.com). Once the page is
  on the `*-my.sharepoint.com` origin, cookies authenticate SharePoint's Graph-compatible REST
  surface, so run in page context:

  ```js
  const b64 = btoa(shareUrl).replace(/=+$/,'').replace(/\//g,'_').replace(/\+/g,'-');
  const txt = await (await fetch(`/_api/v2.0/shares/u!${b64}/driveItem/content`,
                                 {credentials:'include'})).text();
  ```

  `/driveItem` (without `/content`) returns metadata. Stash the payload on `window` and return
  only small projections/summaries from each call — browser bridges block returning raw
  cookie/base64 blobs, and a multi-hundred-KB file should never be pulled through context whole.
- For Intune/Entra data, prefer re-pulling from Graph with the z-account rather than parsing the
  colleague's export: it is authoritative, fresher, and richer. Use their file only to confirm
  the population matches, and say so when the counts differ.

### Automox

- Use Automox MCP tools/resources when available.
- Translate numeric `server_group_id` values to human-readable group names.
- Ask for approval before production-impacting changes.
- For Automox compliance diagnosis, reconcile four distinct axes before explaining a dashboard number (semantics verified 2026-07-12):
  1. `get_compliance_snapshot` is an attention-style compound view and can count reboot-only devices alongside policy failures.
  2. `device_health_metrics.compliance_breakdown` is the authoritative device-compliance boolean; pending work alone does not count against it.
  3. `policy_compliance_stats.overall_compliance` is calculated only across evaluated policy-device results; report its pending population separately.
  4. Legacy `policy_status` / `policy_execution_breakdown` is an execution-state view, not fleet compliance, and can make almost the whole fleet look noncompliant when broad policies remain pending.
- Fully paginate `noncompliant_report` with small pages when detailed reasons are needed; larger responses can be token-truncated. Split records with no `failing_policies` plus `needs_reboot=true` from devices with real policy remediation failures.
- Rank broad pending policies separately from actual failing policies. Active on-demand, diagnostic, required-software, or unscheduled policies can dominate the pending denominator without creating authoritative noncompliance.
- Treat compliance remediation as a staged workflow: reporting-definition cleanup, controlled reboot/rescan of reboot-only or installed-success records, then package/error-family repair. Ask for approval before reboots, scans, policy scope/schedule edits, or other state changes.
- For Automox policy/patch failures, use `scripts\run-screenconnect-automox-diagnostics.mjs` to select affected devices, run read-only ScreenConnect endpoint diagnostics, retrieve output with `GetReport`, and produce JSON/Markdown reports. Verified 2026-06-30 on three online Windows devices.
- For Automox Winget policy failures, use `scripts\run-screenconnect-winget-diagnostics.mjs` for read-only SYSTEM-context Winget/App Installer checks and parser comparison.

### CrowdStrike Falcon

- Use the query-crowdstrike-falcon skill for live Falcon host, alert, Spotlight, and policy reads.
- API is US-2 (`https://api.us-2.crowdstrike.com`). Credentials are in `C:\temp\temp\env.local` until they move to Keeper. Never print the secret.
- Verified 2026-08-19: this client is **read-only**. Hosts, Alerts, Spotlight, host groups, prevention/sensor-update policies, and custom IOC reads work. Contain, RTR, Intel, Discover, and policy writes return 403.
- Join Falcon to other systems by serial; Falcon hostnames are usually `WKS-<serial>`.
- Alerts `status:'new'` is mostly automated-lead context, not EPP detections. Use `type:'ldt'` or `severity:>=50`.
- Vulnerability KPI scoring stays on Rapid7 / analyze-vulnerability-kpis, not Falcon Spotlight counts.

### Rapid7

- Rapid7 was discussed as an upstream finding source.
- No Rapid7 API connection was verified as of 2026-06-29.
- Do not assume Rapid7 credentials or scripts exist until checked.
- Vulnerability/security KPI reporting source of truth shared by Sawyer Oakhurst: SharePoint workbook [Vulnerabilities-20260625.xlsx](https://contoso-my.sharepoint.com/:x:/r/personal/sawyer_oakhurst_contoso_com/Documents/Desktop/Vulnerabilities-20260625.xlsx?d=w3e16d1725b8b4876bacb07c508daa141&csf=1&web=1&e=1AI4X6). For questions about how Contoso is judged on vulnerabilities/security KPIs, start from this workbook.
- Use the analyze-vulnerability-kpis skill for vulnerability KPI/readout prompts, including: "how are we doing on vulnerabilities?", "how do we get better?", "why are we not doing great?", "what is driving our vulnerability score?", "what is hurting the KPI?", "what should we fix first?", "security KPI readout", "vulnerability burn-down", "Sawyer's workbook", or `Vulnerabilities-*.xlsx`.
- Interpretation memory: the workbook is instance-weighted; repeated vulnerability rows with identical instance counts usually point to a shared patch/reboot/stale-device cohort. In the 2026-06-25 workbook, Windows + Edge + Office drove about 97% of instances.
- For Rapid7 device inventory, Automox comparison, and endpoint vulnerability work, default to assets with the Rapid7/Insight agent installed. Non-agent Rapid7 assets are out of scope unless the user explicitly asks for all Rapid7 assets.

## Cross-System Flow

1. Confirm the source system and operational reason.
2. Query live source data.
3. Identify the endpoint across hostname, serial, user, Intune, Automox, ScreenConnect, Rapid7, CrowdStrike Falcon, and Freshservice identifiers.
4. Use Keeper/KSM for secrets.
5. Use ScreenConnect for authorized read-only endpoint diagnostics when needed.
6. Ask approval before changing state.
7. Verify in the originating system.
8. Record concise evidence in Freshservice/change/incident notes.

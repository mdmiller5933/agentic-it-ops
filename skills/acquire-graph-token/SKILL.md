---
name: acquire-graph-token
description: Mint Contoso Graph tokens without asking Avery for device-code or Keeper MFA — app-only cert by default, delegated z_admin via TAP remint. Use when the user asks to use my z account, z_admin, "re-authenticate my Z account", delegated Graph, Exchange as z_admin, MAA approve/reject, remint Graph, NEED_BOOTSTRAP, AADSTS50173, Temporary Access Pass, get a Graph/Intune token, or stop WAM/device-code; or Connect-MgGraph "A window handle must be configured". App-only: graph-app-token.cmd. User-context: Invoke-DelegatedGraphTapRemint.ps1 then graph-token.cmd. Lane: tokens and the MAA write handshake — for what to do WITH access, use it-operations.
---

# Acquire Graph Token (Agent Shell)

Unattended Graph auth for the Contoso tenant (`80bcfe19-ba5c-bcaf-8f4b-1dadba37a010`) from an
agent-spawned shell. The default identity is a **certificate app-only** service principal
(survives the daily Keeper rotation of `z_admin@contoso.com`). Delegated `z_admin` is
the exception, not the default: its refresh store dies at midnight Central when the PAM
password rotates (`AADSTS50173`). Remint it unattended with
`Invoke-DelegatedGraphTapRemint.ps1` (TAP + Playwright device-code, verified 2026-08-18).
ROPC with the Keeper password still hits MFA (`AADSTS50076`); TAP is not a ROPC password
(`AADSTS50126`). Deep background: the "Auth From
the Agent Shell" section of `C:\automox-mcp-main\docs\microsoft-graph-intune-access-runbook.md`
and `C:\automox-mcp-main\scripts\graph-auth\README-app-only.md`.

**Which identity (pick this before any Graph call):**

- Intune/Graph as an app, no `/me`: Step 1 `graph-app-token.cmd` (or `graph-app-token-write.cmd`).
- User-context as `z_admin` (`/me`, Exchange, MAA approve/reject): Step 1b `graph-token.cmd`.
  If it prints `NEED_BOOTSTRAP` / `REFRESH_FAILED` / `AADSTS50173`, run Step 4 TAP remint.
  Do **not** ask Avery for device-code, Keeper MFA, or TOTP. Do **not** ROPC the PAM
  password (`AADSTS50076`) or TAP (`AADSTS50126`).
- **MAA-gated Intune writes (anything that files an operationApprovalRequest — app
  create/update/assign, remediation scripts) must be FILED as delegated `z_admin`, never as the
  app identity** (Avery's audit directive, 2026-08-18). App-filed requests show the service
  principal as "Requested by" — an audit finding — and MAA only blocks approving your *own*
  requests, so the admin who initiated an app-filed change can approve it themselves, defeating
  the four-eyes control. App-only stays fine for reads and non-gated writes. Completion is bound
  to the filing identity (Step 6b), so any legacy app-filed request still completes as the app.
- Never copy `graph-app-token.json` over `graph-token.json`.

**Approval gate:** Graph/Intune writes are production-impacting — get explicit approval from
Avery before creating or changing anything. Reads are fine.

**Host quirk (verified 2026-07-09):** on this workstation, run PowerShell as
`cmd //c "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File <abs-path>.ps1"`. Agent-backgrounded
`powershell.exe` can hang at spawn — if a background task shows no output after ~30 s, stop it
and re-run foreground with that pattern.

**Persistent-process fallback (verified 2026-08-06):** if the normal shell repeatedly returns OS
error 1223 and a persistent JavaScript process is already usable, spawning `cmd.exe /c` with the
`.cmd` wrapper can itself fail with `The syntax of the command is incorrect`. Invoke the wrapper's
underlying script directly through the absolute PowerShell 7 executable instead:

```js
const { execFile } = await import('node:child_process');
await new Promise((resolve, reject) => execFile(
  'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
   'C:\\automox-mcp-main\\scripts\\graph-auth\\Get-AppGraphToken.ps1'],
  { timeout: 60000 },
  (error, stdout, stderr) => error ? reject(error) : resolve({ stdout, stderr })
));
```

Capture and discard the helper's output instead of echoing it. It writes the access-token JSON to
`%TEMP%\graph-app-token.json`; read and use that file in memory, and never print its contents.

## Step 1 — app-only cert (the unattended path; do this first)

This is the hands-off path after change 10035. No Keeper shell, no password, no MFA, no device
code. The signing cert is in `Cert:\CurrentUser\My`; env vars `GRAPH_APP_TENANT_ID` /
`GRAPH_APP_CLIENT_ID` / `GRAPH_APP_CERT_THUMBPRINT` select the **read** identity.

```cmd
cmd //c "C:\automox-mcp-main\scripts\graph-auth\graph-app-token.cmd"
```

On success it prints `TOKEN_ACQUIRED via=cert …` (or `via=cache`) and writes
`%TEMP%\graph-app-token.json`. Use that file (Step 5). Intune **writes** that must run as the
write app use `graph-app-token-write.cmd` → `%TEMP%\graph-app-token-write.json`.

- The JWT has `roles` (application permissions), not `scp` or `upn`. Do not treat it as
  `z_admin`. `/me` will not resolve to a person. MAA approve/reject is still interactive-admin
  only.
- Never copy this file over `graph-token.json`. Assert-GraphToken and Publish-IntuneWin32App
  distinguish the two on purpose.
- `graph-app-token.cmd -Status` reports cert + cache with no network call.
- Delegated `graph-token.cmd` is Step 1b, only when the task truly needs user context.

## Step 1b — delegated z-account (only if Step 1 cannot do the call)

A refresh token for `z_admin@contoso.com` lives DPAPI-encrypted (CurrentUser) in
`%LOCALAPPDATA%\GraphAuth\graph-rt.dpapi`. Midnight Central PAM rotation revokes it
(`AADSTS50173`). Do **not** try Keeper password + ROPC (`AADSTS50076` MFA) or TAP-as-ROPC
password (`AADSTS50126`, verified 2026-08-18). The unattended remint is TAP + Playwright
device-code (Step 4).

```cmd
cmd //c "C:\automox-mcp-main\scripts\graph-auth\graph-token.cmd"
```

On success it prints `TOKEN_ACQUIRED via=refresh …` and writes `%TEMP%\graph-token.json`.
`NEED_BOOTSTRAP` / `REFRESH_FAILED` means the delegated store is dead — run Step 4 (TAP remint)
if the task needs z-account user context; otherwise switch back to Step 1 (app-only).

### Interpreting a standalone `RECOVERED` Teams card (verified 2026-08-12)

Do not treat `Contoso Graph token keepalive RECOVERED` as proof that the credential failed. Diagnose
it read-only from `%LOCALAPPDATA%\GraphAuth\keepalive.log`, `token-health.log`,
`token-health-state.json`, and `token-health-status.json`; do not refresh the token just to inspect
the incident. A confirmed failure has `REFRESH_FAILED` / `NEED_BOOTSTRAP`. In contrast,
`REFRESH_INCONCLUSIVE reason=no-oauth-response` means Entra was never reached, commonly because a
logon/session-unlock trigger ran before Wi-Fi, DNS, or Cato was ready.

The current watcher can emit a one-sided recovery: it persists `state=alert` even when the failure
card's webhook post fails, then sends `RECOVERED` after the next healthy refresh. Check the earlier
`TOKEN_HEALTH: ALERT ... sent=false` lines before assuming Teams ever received the failure card.
The live task can also drift from `Install-GraphTokenKeepAlive.ps1`; compare its triggers/actions
before reinstalling, because the installer defines daily + logon refresh only while the live task
may also contain session-unlock and health-watcher wiring.

Script: `Update-GraphToken.ps1` in `C:\automox-mcp-main\scripts\graph-auth`. Never print the
token or the store contents.

## Step 2 — SDK-cache hydration (only if you specifically need Connect-MgGraph / Invoke-MgGraphRequest)

Prefer Step 1. If a task must use the Graph SDK cmdlets rather than raw REST, note each NEW
PowerShell process starts with an empty in-memory context (`Get-MgContext` returns nothing,
verified 2026-07-13). Hydrate silently from the CurrentUser cache — this does NOT trigger
interactive sign-in when the cache holds the scopes:

```powershell
$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.Account) {
    Connect-MgGraph -NoWelcome -ContextScope CurrentUser -Scopes @('User.Read','<task scopes>')
}
```

**When that cache is cold, do NOT fall back to interactive — bridge the Step 1 token into the SDK**
(verified 2026-07-29, module 2.38.0). `-ContextScope CurrentUser` still attempts interactive on a
cache miss and dies with "A window handle must be configured". Feeding the DPAPI-store access
token to `-AccessToken` yields a fully usable context — `AuthType=UserProvidedAccessToken`,
`Account` populated from the `upn` claim (so callers that assert on `Get-MgContext().Account`
pass), and `Invoke-MgGraphRequest` works:

```powershell
$raw = (Get-Content "$env:TEMP\graph-token.json" -Raw | ConvertFrom-Json).access_token
Connect-MgGraph -AccessToken (ConvertTo-SecureString $raw -AsPlainText -Force) -NoWelcome
```

Verify the token carries the scopes the caller wants first (decode the `scp` claim); a gap
otherwise surfaces later as an opaque `403` mid-operation. To make a third-party script that calls
`Connect-MgGraph` itself work unmodified, define a `function Connect-MgGraph` in the calling scope —
functions outrank cmdlets and parent-scope functions are visible to a script invoked with `&` — and
have it call `Microsoft.Graph.Authentication\Connect-MgGraph -AccessToken ...` (module-qualified, or
it recurses). That leaves the script's own safeguards untouched.

`cmd //c "C:\automox-mcp-main\scripts\intune-auth-test.cmd"` reports whether the cache holds the
z-account and required scopes.

## Step 3 — dead ends; do NOT retry these (all verified failing 2026-07-09)

- `Connect-MgGraph` interactive: dies with "A window handle must be configured" — the nested
  shell has no window the WAM broker can attach to. `Set-MgGraphOption -DisableLoginByWAM` does
  not help (tested through module 2.38.0), nor does upgrading the module.
- `Connect-MgGraph -UseDeviceCode`: a hard-coded 120-second inactivity watchdog abandons the
  device code while the user is still completing MFA/consent, then silently rotates codes. The
  user's browser sign-in "succeeds" but no token is ever collected. `-ClientTimeout` does NOT
  extend this (it is HTTP-only). Do not burn the user's MFA attempts on it.
- Guessing Exchange scope names. The EXO delegated scopes are **`Exchange.Manage`**,
  **`Exchange.ManageV2`**, **`Exchange.AdminAPI.Manage`** and nothing else. `AdminApi.AccessAsUser.All`
  / `EXO.PowerShell.AccessAsUser.All` do not exist on that resource and return `AADSTS65001`, which
  reads like a consent problem and is really a bad name. Enumerate first (Step 2b) instead of guessing.
- Trusting `aud` alone on a cross-resource redeem. Redeeming for
  `https://outlook.office365.com/.default` returns HTTP 200 with the right audience even when no
  Exchange scope is consented, and the `scp` silently comes back as Graph directory scopes only.
  `Connect-ExchangeOnline -AccessToken` then fails with a bare `UnAuthorized` (both String and
  SecureString). **Always decode `scp`, not just `aud`.**

## Step 2b — Exchange Online PowerShell off the same store (verified 2026-07-31, EXO module 3.9.2)

Works, and needs a one-time delegated grant because the store's client
("Microsoft Graph Command Line Tools") ships with no Exchange consent. The EXO module's own client
is unreachable (refresh tokens can't cross clients), so grant Exchange scopes to *this* client.

One-time setup, **Principal-scoped to the z-account only** (matches the tenant's existing pattern;
tenant-wide `AllPrincipals` is not needed and widens blast radius):

```
POST https://graph.microsoft.com/v1.0/oauth2PermissionGrants
{ "clientId": "<Graph CLI Tools servicePrincipal id>", "consentType": "Principal",
  "principalId": "<z-account user id>", "resourceId": "<Office 365 Exchange Online sp id>",
  "scope": "Exchange.Manage Exchange.ManageV2 Exchange.AdminAPI.Manage" }
```

Resolve both service principals by appId at run time (`servicePrincipals(appId='…')`): the client is
`14d82eec-204b-4c2f-b7e8-296a70dab67e`, Exchange Online is the well-known
`00000002-0000-0ff1-ce00-b531639fc81f`. All three scopes are `type=User`, so no admin-consent
escalation is involved, and the delegated token is still bounded by the z-account's Exchange RBAC
role. Reversible: `DELETE /v1.0/oauth2PermissionGrants/{id}`. Requires Cloud Application
Administrator (held). Grant is effective immediately, no propagation wait observed.

Then per session:

```powershell
# redeem store RT for scope 'https://outlook.office365.com/.default offline_access'
Connect-ExchangeOnline -AccessToken $raw -Organization 'contoso.com' -ShowBanner:$false
```

Pass the token as a **plain string**, not a SecureString. **Cross-resource redeems rotate the
refresh token** — back up `graph-rt.dpapi` and persist the rotated RT in the same format, or the
Graph path breaks too.

Known gaps on this token, none fatal:
- `Get-HVEAccountBillingPolicy` fails `"Failed to get SPO billing policies"` (it proxies a
  SharePoint-side read the grant doesn't cover); read billing state from the Exchange admin center UI.
- `Search-AdminAuditLog` no longer exists in module 3.9.2. Use
  `Search-UnifiedAuditLog -FreeText <term> -StartDate -EndDate`, which works fine.
- `Search-UnifiedAuditLog` emits a red `401 / "Failed to get user scopes"` + "ignore AU check"
  warning block, then returns correct results anyway. Benign, don't chase it.
- `Set-MailUser -Password` can fail `"Recipient … couldn't be read from domain controller …
  Switching out of Forest mode should allow this operation"` on a freshly created recipient.
  Fall back to Graph `PATCH /users/{id}` with
  `passwordProfile = @{ password = …; forceChangePasswordNextSignIn = $false }`, which works.

Audit tip: to find **which human** performed an Exchange admin-center action, use the unified audit
log. Entra directory audit attributes EAC actions to service principals ("Microsoft Substrate
Management", "Microsoft Approval Management") and never names the admin.

## Step 4 — TAP remint (delegated keep-alive; no Avery)

Daily PAM rotation kills every z_admin refresh token. The TAP remint app
(`a61d52b4-19a5-5e01-208c-7d946e5fdb23`, cert thumbprint `DF87C0B146877AAFF1E895873AB76BACB6009A5A`)
creates a one-shot Temporary Access Pass for z_admin only, then Playwright completes
`login.microsoft.com/device` (code → UPN → TAP field, not the password box → Continue on
"Are you trying to sign in to Microsoft Graph Command Line Tools?"). Verified 2026-08-18:
`TOKEN_ACQUIRED via=tap-device-code`, `/me` = z_admin, Exchange `scp` includes
`Exchange.Manage*`. ROPC with TAP as the password is a dead end (`AADSTS50126`).

Scheduled task `Contoso Delegated Graph TAP Remint` (interactive logon, 00:20 local + at logon)
runs this. If the store still refreshes, the script exits 0 without creating a TAP.

```cmd
cmd //c "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\automox-mcp-main\scripts\graph-auth\Invoke-DelegatedGraphTapRemint.ps1"
```

`-Force` remints even when the store is healthy (proof / after a CA reset). Log:
`%LOCALAPPDATA%\GraphAuth\tap-remint.log`. Never print TAP or tokens. After remint, Exchange
redeem is included unless `-SkipExchange`; always decode `scp` for `Exchange.Manage`.

Human device-code (`graph-token.cmd -Bootstrap -AllowDeviceCode`) is only if TAP remint fails
and the user said they are standing by. Do not generate codes they are not waiting for.

Standalone device-code script (no store side effects) also exists:
`scripts/get-graph-token.ps1` inside this skill's folder (copy at
`C:\automox-mcp-main\scripts\get-graph-token-devicecode.ps1`, verified 2026-07-09).

## Step 5 — use the token

Unattended (Step 1) file is `graph-app-token.json`. Delegated (Step 1b) file is `graph-token.json`.

```powershell
$tok = (Get-Content "$env:TEMP\graph-app-token.json" -Raw | ConvertFrom-Json).access_token
$H = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" }
Invoke-WebRequest -Method POST -Uri "https://graph.microsoft.com/beta/..." -Headers $H -Body $json -SkipHttpErrorCheck
```

App-only tokens last ~60 minutes; re-run Step 1 (silent, cert). The durable secret is the
certificate in `Cert:\CurrentUser\My`, not the token file. For the rare delegated path, the
durable secret is the DPAPI refresh store — it dies when the z-password rotates.

## Step 6 — MAA-gated Intune writes (apps, remediation scripts, more)

**Filing identity: delegated `z_admin` (Step 1b), not app-only** — see the identity block at the
top. The Intune Win32 publisher takes `-DelegatedGraph` for this. Filing as the app makes the
"Requested by" column a service principal and lets the initiating admin self-approve
(directive verified 2026-08-18).

If a write returns `400` with `"Header 'x-msft-approval-justification' is required to request approval"`:

1. Re-send the SAME request with one extra header — `x-msft-approval-justification:` set to the
   **base64** of a plain-English justification (what, why, scope, requester). Raw text is rejected.
   **The DECODED justification must be ≤ 1024 characters** (verified 2026-07-29). Over that, the
   write fails `400 BadRequest` — `"Decoded content of 'x-msft-approval-justification' header must
   be no greater than 1024 characters"` — and NO approval request is filed, so a long justification
   silently costs a whole round trip. Assert the length locally before sending. Note the failure
   arrives late in a multi-step flow: for a Win32 app upload the app, content version, and committed
   content all succeed first, and only the final activating PATCH is rejected — leaving a
   `notPublished` draft to resume, not a clean pryce.
   **Store-app create exception (verified 2026-07-17):** a `POST` that returns this `400` can still
   allocate a `processing` `winGetApp` stub. For a create operation already known to be MAA-gated,
   pre-supply the justification header on the first request. If a no-header create already returned
   `400`, audit exact-name apps and pending approval requests before retrying; never blindly replay
   the `POST`. Preserve the stub targeted by MAA and remove only a separately verified, zero-assignment
   orphan after confirming its ID is not the approval payload ID.
2. Expect `412 PreconditionFailed` with an `x-msft-approval-code` response header. That means the
   request is now FILED and pending an `AZ-Intune-Approvers` member — this is success, not an error.
   A repeat attempt returns `409` ("active Approval Request already exists").
3. Nothing exists/changes until an approver acts in the Intune console. Record the approval code,
   report it to the user, and note any follow-up steps (e.g. assignments) that must wait for approval.

### Step 6b — COMPLETE an approved request (verified 2026-07-28; approval alone changes nothing)

Approval is not application. A request sitting at `status=approved` shows in the portal as
**"Approved - Needs completion"** and the change has NOT happened yet. The requestor must complete
it. Do not assume the portal button is available — complete it over Graph:

**"The approve button is greyed out for me" is usually this state, not a permissions problem**
(verified 2026-08-13). Diagnose before touching anything: `GET …/operationApprovalRequests` and read
`status`. `approved` means approval already happened — there is nothing left to approve, and the
grey button is correct. Then read **`requestor`** to pick the completing identity, because MAA
completion is bound to the identity that FILED the request:
- `requestor.application` = the Intune-write app (`697ed9f7-…`, "Contoso EUC Automation - Intune
  Write") → no portal user can ever complete it; run the completion script with its **default App
  identity**. A human's delegated token is the wrong identity here.
- `requestor.user` = a z-account that filed it interactively → pass **`-Delegated`**.
Guessing wrong costs a round trip: the write app 404s requests it cannot see, and a cross-identity
completion returns a bare `403` that looks like an auth failure.

```
POST https://graph.microsoft.com/beta/<the original resource collection>
x-msft-approval-code: <operationApprovalRequest.id>      # RAW GUID
body: the request's addedAssignments[n] object, VERBATIM
```

Rules, each one learned from a failure:

- **Use `x-msft-approval-code`, not `x-msft-approval-justification`.** They are mutually exclusive.
  Sending the justification header on completion files a NEW request and returns
  `409 "An active Approval Request already exists for this entity"`.
- **The approval code is the `operationApprovalRequest.id`**, sent as a raw GUID. Base64-encoding it
  returns `400 "Invalid approval header format, expected GUID format"` — the opposite of the
  justification header's encoding rule, which is easy to get backwards.
- **Complete on the SAME endpoint the request was FILED on** (corrected 2026-07-30 — an earlier
  version of this rule said always use the granular POST, which fails outright for bulk filings).
  `payloadOperation` reads `"Assign"` either way and does not tell you which; **`actionParameters`
  does** — it is populated only for a bulk filing, and it holds the exact body to replay.
  - Filed via `POST …/mobileApps/{id}/assignments` (one new entry) → complete via `/assignments`,
    body = that `addedAssignments[n]` object.
  - Filed via `POST …/mobileApps/{id}/assign` (whole desired list) → complete via `/assign`,
    body = the request's `actionParameters` string verbatim. Here `addedAssignments` restates the
    ENTIRE list, including entries already live, so looping it into `/assignments` one at a time
    gives a bare `403` on the first call.
  Crossing the two returns `403 "An error has occurred"` from `proxy.msua09.manage.microsoft.com` —
  indistinguishable from an auth failure, but really an operation mismatch. The `403` is clean: the
  entity is NOT modified, so a wrong first guess costs a round trip, not a repair job.
- **POST the `addedAssignments` element verbatim.** Its casing is Intune-internal
  (`"intent": "Required"`, `"@odata.type": "microsoft.graph.MobileAppAssignment"`, plus
  `"source": "Direct"`) and it is accepted as-is. A hand-normalized `#microsoft.graph.…` version is
  not worth the risk — read the object off the request and pass it straight through.
- **`/assign` REPLACES the whole assignment collection** — at both filing and completion. That is
  survivable but never blind: read live assignments first and assert the outgoing list is a strict
  superset of them, aborting otherwise. Prefer `/assign` when adding several groups at once (one
  approver cycle instead of N, and only one request can be pending per app — a second change while
  one is pending `409`s). Prefer the additive `/assignments` POST for a single group, since it
  cannot drop anything.
- Confirm afterwards: the request flips to `status=completed`, and
  `POST /deviceManagement/operationApprovalRequests/retrieveRequestStatus` with
  `entityType=Microsoft.Management.Services.Api.MobileApp` reports the entity unlocked. Use that
  exact fully-qualified `entityType` — short forms like `MobileApp` silently return a bogus
  requestId that 404s on lookup.

Working scripts in `C:\automox-mcp-main\scripts` — both gate on `status=approved`, verify no live
assignment was lost, and re-check the request status after:
- `complete-maa-request.ps1 -RequestId <guid>` — granular `/assignments` route (filing had no
  `actionParameters`).
- `complete-maa-assign-bulk.ps1 -RequestId <guid>` — bulk `/assign` route, replays
  `actionParameters` verbatim behind a superset guard; supports `-WhatIfOnly`.

Do not read the app's computed `isAssigned` property as proof — it can stay `false` in this tenant
while assignments are live (observed 2026-07-30 both before and after a successful change). The
`/assignments` collection is authoritative.

### Step 6c — completing an `Update` (metadata PATCH) request (verified 2026-07-28)

`payloadOperation: "Update"` has no `addedAssignments`; the write to replay is a PATCH of the
entity itself, with the body taken from the request's `patchPayload` string:

```
PATCH https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{payloadId}
x-msft-approval-code: <operationApprovalRequest.id>      # RAW GUID
body: the request's patchPayload, @odata.type repaired
```

- **Repair EVERY `@odata.type` in the payload graph, nested ones included; change nothing else.**
  `patchPayload` ships legacy internal names (`#microsoft.management.services.api.winGetApp`);
  rewrite each to its `#microsoft.graph.*` form. This is unavoidable even for a request you filed
  yourself over Graph with the correct type — the service rewrites them when it stores the payload.
  It rewrites **child objects too**: a `detectionRules`-only PATCH came back with both the root
  `win32LobApp` and the nested `win32LobAppPowerShellScriptDetection` renamed (verified 2026-08-03),
  so a root-only repair leaves a legacy name behind and the completion PATCH fails. Walk the whole
  object graph, then assert no `microsoft.management.services.api` string survives before sending.
- **The rest of the payload must match what was approved.** Substituting even one field's value
  makes the approval code itself be rejected with a bare `403 Forbidden` (same signature as using
  the wrong endpoint). There is no partial completion — you cannot drop a field to dodge a
  validation error.
- **A portal-filed approval carrying an icon may be permanently uncompletable.** The portal accepts
  an image at upload without checking its container and stores it in `patchPayload` as
  `"type":"image/png"`; if the file is actually WEBP, verbatim replay fails
  `400 "Icon in invalid format."` from `StatelessAppMetadataFEService`, while supplying a real PNG
  fails `403` per the rule above. Both failures are clean — the entity is not modified. Detect it
  up front: base64-decode `largeIcon.value` and check the magic bytes (`RIFF`+`WEBP` at offsets
  0 and 8 means WEBP, regardless of a `.png` filename).
- **Escape hatch:** cancel, then re-file the PATCH yourself with `x-msft-approval-justification`
  and a genuine PNG. Filing over Graph avoids the bug, because the stored payload is then the valid
  one you sent, and completion succeeds. Re-filing costs a second approver cycle — get the user's
  go-ahead first, and use the re-file to also correct any stale `description`/`notes` text the old
  payload carried forward. `cancelMyRequest` is bound to the **collection**, with the request id in
  the body — appending the id to the path gives `400 "No method match route template"`, and an
  empty body gives `400 "Empty Payload. JSON content expected."`:

```
POST https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests/cancelMyRequest
body: { "id": "<operationApprovalRequest.id>" }        # -> 204, status flips to 'cancelled'
```

  `retrieveRequestStatus` is collection-bound the same way. When an approval action's route is in
  doubt, read the binding out of `https://graph.microsoft.com/beta/$metadata` (~7 MB; grep for
  `<Action Name="…"` and its `bindingParameter` type) rather than guessing path shapes —
  `Collection(graph.…)` means collection-bound, not entity-bound. Note `operationApprovalRequests`
  is beta-only; on v1.0 the segment does not resolve at all.
- Re-encode a WEBP to PNG with no extra tooling: this platform's imaging stack decodes WEBP, so
  `[Windows.Media.Imaging.BitmapDecoder]` + `PngBitmapEncoder` (assemblies `PresentationCore`,
  `WindowsBase`) round-trips it. Verify the result starts `89 50 4E 47 0D 0A 1A 0A`.

Working script: `C:\automox-mcp-main\scripts\complete-maa-update-request.ps1 -RequestId <guid>`
— gates on `status=approved` + `operation=Update`, repairs the type name, reports the icon's real
container, and supports `-WhatIfOnly` and `-IconPath` (re-file path only).

# Publish a Win32 App to Intune

Run this only after the user explicitly approves the upload. It creates the Intune app and uploads
content, but intentionally does not create assignments.

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Publish-IntuneWin32App.ps1 `
  -PackagePath '<version>\OUTPUT\Install-App.intunewin' `
  -SetupFilePath 'Install-App.ps1' `
  -DetectionScriptPath '<app>\Detection.ps1' `
  -DisplayName 'App' `
  -Description 'Enterprise deployment of App for Windows.' `
  -Publisher 'Vendor' `
  -InstallCommandLine 'powershell.exe -ExecutionPolicy Bypass -File .\Install-App.ps1' `
  -UninstallCommandLine 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-App.ps1' `
  -LogoPath '<version>\CompanyPortalLogo.png' `
  -Version '<version>' `
  -GraphApiVersion 'beta' `
  -DeploymentIntent 'CreateSeparateTest' `
  -SummaryPath '<version>\IntuneUpload-App.json' `
  -Justification 'Publish App Win32 package to Intune. No assignments are included.'
```

`-SetupFilePath` is the exact setup filename embedded in the `.intunewin` manifest (for example,
`Install-App.ps1`), not the source file's full local path. The publisher compares that leaf name
verbatim. Run this publisher with PowerShell 7 (`pwsh.exe`); Windows PowerShell 5.1 can load an
incompatible `Microsoft.Graph.Authentication` assembly and fail with an unimplemented
`GetTokenAsync` method before the Graph write.

Select the deployment intent before running the publisher. `CreateSeparateTest` is the safe default: use a
separately named app such as `(TEST) App`, do not pass `-ExistingAppId`, and leave it unassigned until the
user explicitly names a pilot target. Use `UpdateExisting` only when the user explicitly approves updating
one identified production app, and pass that exact ID with `-ExistingAppId`. The publisher rejects a mismatch
between the selected intent and `-ExistingAppId`.

`-InstallRunAsAccount user|system` (default `system`) sets the app's install context — **create-time
only**. Intune rejects the activation PATCH on an existing app with `400: The 'RunAsAccount' property
cannot be patched for the 'Win32LobApp' type` (verified 2026-08-05); fixing a wrong context means a new
app. When that 400 (or any activation rejection) happens after upload, the new content version is already
committed but not activated: the app stays on its previous version and no MAA request was filed. That
orphan committed version is harmless, but account for it before re-uploading — or activate it later via
`-ActivateContentVersionId`.

For `UpdateExisting`, the publisher now omits `installExperience` entirely and rejects an explicitly
supplied `-InstallRunAsAccount`, preserving the existing run context, restart behavior, and maximum run
time. Verify those live values before and after the update. Use `-ReturnCodeProfile Strict` when the
wrapper must accept only `0`, `1618`, `3010`, and `1641`; the default profile retains Intune's normal
`1707=success` mapping. Use `-AvailableUninstallPolicy Disable` to set
`allowAvailableUninstall=false` without changing assignments; its default is `Preserve`.

`-NewDisplayName '<name>'` renames during `UpdateExisting`: `-DisplayName` must still match the app's
CURRENT name (identity check), the publisher refuses to rename onto an existing app with the target name,
and the rename rides the same activation PATCH (one MAA cycle).

The uploader requires the delegated Graph scope `DeviceManagementApps.ReadWrite.All`. It detects
Intune Multi Admin Approval (MAA), writes `approvalRequired` with the request ID to the summary, and
does not retry the protected write. A same-name app is treated as a stop condition, except an explicitly
requested reuse of an unpublished draft created by this uploader.

Win32 `displayVersion` is exposed through the Graph beta resource (verified 2026-07-28). When passing
`-Version`, also pass `-GraphApiVersion beta`; the publisher refuses that metadata combination on v1.0
instead of allowing Intune to silently drop the version from the approval payload.

An activation can instead return `409 Conflict` with `An active Approval Request already exists`. That is
not a content failure and must not be retried. Query
`/beta/deviceManagement/operationApprovalRequests?$filter=status eq 'needsApproval'`, match the app's
`payloadId`, and report the approval record ID and expiration. After approval, poll the app's
`committedContentVersion`; the stored approval payload may activate it automatically.

### Complete an approved MAA request

For a Graph-created request that remains `approved`, re-submit the original write with the
`x-msft-approval-code` header. Before writing, verify that the request's `payloadId`, `payloadName`,
`payloadOperation`, and committed content version match the intended app. Rebuild the same Graph-native
payload that was originally submitted, then use the approval request ID as the approval code:

```powershell
Invoke-MgGraphRequest -Method PATCH `
  -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/<app ID>' `
  -Headers @{ 'x-msft-approval-code' = '<approved request ID>' } `
  -Body '<the original Graph-native JSON payload>' `
  -ContentType 'application/json'
```

Do not replay `operationApprovalRequest.patchPayload` verbatim. Intune can serialize it with legacy types
such as `microsoft.management.services.api.win32LobApp`; the v1.0 endpoint rejects those with an invalid
OData type error. After completion, verify the approval request is `completed`, the target app is published
on the expected content version, and the assignment count is unchanged.

#### Portal reports "The payload could not be read"

Verified 2026-07-27 for a protected Win32 app assignment: the Intune portal can fail **Complete
request** with `The payload could not be read` while the Graph approval record remains valid and
`approved`. Do not cancel or recreate the request solely because of that portal error.

1. GET the approval record, target app, target group, and the app's live assignments.
2. Require the request to be `approved`; verify its exact `payloadId`, `payloadName`, and
   `payloadOperation = Assign`.
3. Parse `addedAssignments` only to validate that it contains one expected assignment with the exact
   intent, group ID, filter type, Win32 settings type, notification setting, and delivery priority.
4. Confirm an equivalent live assignment does not already exist. If it does, do not create a duplicate;
   re-read the request status and verify the existing assignment instead.
5. Rebuild a canonical `#microsoft.graph.mobileAppAssignment` body rather than replaying the serialized
   `addedAssignments` string. POST it to
   `/beta/deviceAppManagement/mobileApps/<app ID>/assignments` with the approved request ID in
   `x-msft-approval-code`.
6. Verify `201 Created`, then require the approval record to become `completed` and re-read every
   assignment and relationship on both apps to prove the intended group is the only new target.

If a pending MAA request targeted the wrong app, cancel it before anyone can approve it:

```powershell
Invoke-MgGraphRequest -Method POST `
  -Uri 'https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests/cancelMyRequest' `
  -Body (@{ id = '<approval request ID>' } | ConvertTo-Json) `
  -ContentType 'application/json'
```

Then verify the production app's `committedContentVersion` and assignments have not changed before creating
the separate test app.

### Configure a Win32 dependency

Verified 2026-07-27: the Intune service can reject
`POST /beta/deviceAppManagement/mobileApps/<parent ID>/relationships` with
`No method match route template`, even though the generated create documentation lists that route.
Use the supported action on the exact published parent app instead:

```http
POST /beta/deviceAppManagement/mobileApps/<parent ID>/updateRelationships
Content-Type: application/json

{
  "relationships": [
    {
      "@odata.type": "#microsoft.graph.mobileAppDependency",
      "targetId": "<dependency app ID>",
      "dependencyType": "autoInstall"
    }
  ]
}
```

Before writing, GET both app IDs and verify they are the intended Win32 apps, then GET the parent's
current relationships. `updateRelationships` sets the relationship collection, so preserve any intended
existing relationships and refuse unexpected ones. Supply the base64 MAA justification header on the
first protected write. If Intune returns `412` with `x-msft-approval-code`, leave the request pending;
after approval, validate its app ID, app name, `Action` operation, and original relationship body before
resubmitting the same action with that approval code. Finally, GET the parent relationship collection and
verify the exact dependency app ID and `autoInstall` type.

To replace the content of an already-published Win32 app without altering its assignments, add
`-DeploymentIntent 'UpdateExisting' -ExistingAppId '<Intune app ID>'`. The uploader uploads and validates the new content first, then
activates the new content version and its metadata in one PATCH request. It does not create, remove, or
change assignments.

The script extracts and uploads the encrypted content inside the `.intunewin`; do not upload the outer
`.intunewin` directly to the content-file Azure URL. It must upload the encrypted inner payload as block
blobs and finish with a block list. A single PUT can receive an Azure success response but still cause
Intune to report `commitFileFailed` after the Graph commit call. Use a PNG for `-LogoPath`; the uploader
validates its signature before Graph receives it.

Successful progression is `azureStorageUriRequestSuccess`, then `commitFilePending`, then
`commitFileSuccess`. If the final state is `commitFileFailed`, the content version is not committed and
the published app remains on its previous version. Do not patch `committedContentVersion` or change an
assignment in that state. Confirm the encrypted metadata came directly from `Detection.xml` and create a
new content version only after correcting the transport or metadata issue.

If a session ends after `commitFileSuccess` but before the activation PATCH, resume without uploading again:
use both `-ExistingAppId '<app ID>'` and `-ActivateContentVersionId '<validated content version>'`. The
publisher verifies that the supplied version has exactly one committed file in `commitFileSuccess` before
activating it with the requested metadata.

---
name: package-intune-win32-app
description: Create, package, and, after explicit approval, upload Microsoft Intune Win32 app deployments (.intunewin). Use when the user asks to package, wrap, prepare, upload, publish, or "test this app separately" for Intune or Company Portal - e.g. "package X for Intune", "make an intunewin", "upload this Win32 app", "add a Company Portal icon", "pull the app logo", or "write install/uninstall/detection scripts" - covering the app/version INPUT/OUTPUT folder convention, reliable scripts and detection, official logo extraction, mandatory SYSTEM-context install/uninstall/detection lifecycle testing on a test endpoint BEFORE any upload or MAA request, explicit test-vs-update intent, Intune Graph upload, first-publish assignment scoped to the AZ-TEST-EUC-Users group, and toast notifications hidden on every assignment.
---

# Package Intune Win32 App

## Overview

Build Intune Win32 app packages as repeatable deployment folders with scripts, detection, validation, and a final `.intunewin`. Prefer conservative, enterprise-safe defaults: SYSTEM install context, machine-wide install location when possible, useful logs, explicit detection, and clean uninstall behavior.

## Folder Pattern

Use this layout unless the user asks for another convention:

```text
<Intune Apps root>
└── <App Name>
    ├── Detection.ps1
    └── <Version>
        ├── INPUT
        │   ├── <installer>
        │   ├── Install-<App>.ps1
        │   └── Uninstall-<App>.ps1
        └── OUTPUT
            └── <generated>.intunewin
```

Place the installer and install/uninstall scripts in `INPUT`. Place detection at the app parent so it can remain version-agnostic when patching is handled outside Intune.

If the version is not provided, verify the latest version from an official vendor source before naming the version folder. If the user already downloaded the installer, inspect the filename and product metadata where practical.

## Script Defaults

Write PowerShell scripts with these defaults:

- Set `$ErrorActionPreference = 'Stop'`.
- Log wrappers with `Start-Transcript` under `%ProgramData%\Microsoft\IntuneManagementExtension\Logs`.
- Use `$PSScriptRoot` to find payload files.
- Quote installer arguments that contain paths, especially `/LOG` and install directory arguments.
- Treat `0` as success and `3010` as success with reboot required.
- Validate the installed or removed state before returning success.
- Avoid deleting user data or broad profile paths unless the user explicitly asks.
- For x64 machine-wide apps, do not trust `$env:ProgramFiles` unless the wrapper is definitely running
  in 64-bit PowerShell. Either self-relaunch through `%WINDIR%\SysNative\WindowsPowerShell\v1.0\powershell.exe`
  when `$env:PROCESSOR_ARCHITEW6432` is set, or use `$env:ProgramW6432` / `[Environment]::GetFolderPath('ProgramFiles')`
  for install-path validation and cleanup. This prevents Intune's 32-bit agent host from checking
  `C:\Program Files (x86)` while the vendor installer writes to `C:\Program Files`.
- Same 32-bit trap for the registry: if the wrapper seeds vendor config under `HKLM\SOFTWARE\...`, a
  wrapper running 32-bit has its writes silently redirected to `HKLM\SOFTWARE\WOW6432Node\...`, where a
  64-bit app never reads them. Write the 64-bit view explicitly, independent of wrapper bitness:
  `[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)`
  (or `reg add ... /reg:64`). Symptom: values land under `WOW6432Node` but the app behaves as if
  unconfigured. See the intune-win32-registry-wow6432-redirection memory.

For installs to `C:\Program Files`, add an explicit elevation/SYSTEM check. For Intune, assume install behavior should be **System** unless the app is intentionally per-user.

**Install behavior is create-time-only.** Intune rejects PATCHing `RunAsAccount` on an existing
Win32 app (`400: The 'RunAsAccount' property cannot be patched for the 'Win32LobApp' type`,
verified 2026-08-05). Picking the wrong context costs a replacement app, so decide it with
evidence before the first upload.

**electron-builder one-click NSIS trap (verified 2026-08-05, Plaud 1.3.7):** these installers
accept `/ALLUSERS` without error but silently ignore it — a SYSTEM-context run exits 0 and
installs per-user into the SYSTEM profile (the 32-bit installer's LocalAppData writes redirect to
`C:\Windows\SysWOW64\config\systemprofile\AppData\Local\Programs\<App>`, uninstall entry lands in
`HKU\S-1-5-18` with `/currentuser`). A per-user smoke test proves nothing about per-machine
support: before choosing System context for a one-click NSIS/Electron installer, prove the
machine-wide signal (Program Files exe or HKLM uninstall entry) appears in a real SYSTEM run —
otherwise package it as **User** context with plain `/S`.

For user-context apps, remember detection scripts still run as SYSTEM: scan the loaded `HKU\*`
user hives for the uninstall entry (skip `S-1-5-18/19/20` and `*_Classes`), resolve each SID's
profile via ProfileList, and verify the exe inside that profile before reporting detected.

## Install Script Pattern

Create an install script that:

1. Creates the log directory if missing.
2. Optionally calls the local uninstall script first to remove unmanaged old installs and per-user remnants.
3. Finds the installer in `INPUT` using a scoped pattern.
4. Runs the installer with vendor-specific silent flags.
5. Verifies the expected registry key, executable, service, MSI product, or app-specific signal exists.
6. Emits useful version/path output and exits with the installer exit code.

For apps users may actively have open, prefer an in-place repair/patch path over uninstall/reinstall
when the vendor installer supports it. For MSI/MSP packages, drive `msiexec` directly when useful:
repair/reconfigure the MSI with the transform, apply the MSP over the top, then run post-install
cleanup/enforcement. Use uninstall-first only when in-place install is unsupported or leaves the
product in an unsafe state.

When post-install cleanup removes plugin files that the app may lock while open, check for the
app process before touching files. Prefer returning a retry exit code before partial cleanup over
force-closing the app or failing midway with access denied. In Intune, map that code to Retry.

Prefer installing machine-wide when vendor-supported. If the installer has options for PATH, certificate store, credential provider, auto-update, desktop shortcuts, or shell extensions, choose enterprise-friendly defaults and document them briefly in the final response.

## Uninstall Script Pattern

Create an uninstall script that discovers the app rather than assuming a single path. Check relevant sources:

- HKLM uninstall keys, including WOW6432Node where applicable.
- App-specific HKLM vendor keys.
- Loaded HKU uninstall keys for per-user installs.
- Known per-user install folders such as `C:\Users\*\AppData\Local\Programs\<App>` when the app commonly installs there.
- Installer-specific uninstallers such as `unins*.exe`, MSI product codes, or vendor uninstall commands.

When invoking per-user uninstallers from SYSTEM, avoid logging to protected locations from the child uninstaller. Use a wrapper transcript in the Intune logs folder, but use `%TEMP%` for child uninstaller logs unless proven safe.

After uninstalling, wait briefly and re-run detection logic. Return success only when managed install signals are gone. Remove stale app-specific uninstall registry keys only when the install path no longer contains the app executable and the key clearly belongs to that app.

## Detection Script

Use Intune custom detection scripts for these packages. By default:

- **Detection is ALWAYS version-agnostic** (standing directive, 2026-08-18): detect product
  identity + main-executable presence, never a pinned version. Automox owns third-party patching
  fleet-wide, so a version-pinned rule flips to notInstalled the moment Automox updates the app —
  Intune then re-offers the package in Company Portal and can reinstall an older build over the
  patched one, fighting the patch loop. If a minimum version genuinely matters, use a floor
  comparison (`>=`, like the Foxit identity+floor script) so patched-forward installs still
  detect — never equality.
- Detect the managed install scope only. For machine-wide Intune apps, prefer HKLM and `C:\Program Files` signals; do not let a leftover per-user install make Intune think the managed app is installed.
- Output a clear detected/not-detected message.
- Exit `0` when detected and `1` when not detected.
- Tell the user to run detection as 64-bit PowerShell when Intune offers the choice.
- If wrapper logic removes or disables a risky feature, include that post-install condition in detection
  when practical; otherwise Intune can report success after the vendor installer succeeds but wrapper cleanup fails.

Version-pinned (equality) detection is an exception that requires the user to explicitly ask for
Intune-enforced versioning — and call out the conflict with Automox patching before building it.

**Never gate detection on a sentinel written by a boot-triggered or logon-triggered task**
(verified 2026-08-05). A wrapper that defers post-install work to an `ONSTART` scheduled task and
then requires that task's completion file in detection looks rigorous, but the user controls when
the machine reboots. Until they do, the app is fully installed and working while Intune reports
`notInstalled` and Company Portal keeps offering the whole download again - on a multi-GB package
that is a very expensive accidental click. The symptom to recognize: the install-status report says
`S3`/`notInstalled` while the device's own `detectedApps` inventory lists the product. Detect on the
durable installed-state signal (ARP entry, file, service) and demote the completion sentinel to
informational text in the detection output. If post-install work genuinely must finish before the
app is usable, make the wrapper do it synchronously or return a reboot code - do not encode it as a
detection condition.

## Packaging

Use Microsoft Win32 Content Prep Tool:

```powershell
IntuneWinAppUtil.exe -c "<App>\<Version>\INPUT" -s "Install-<App>.ps1" -o "<App>\<Version>\OUTPUT" -q
```

Use the install script as the setup file, not the vendor installer, when the package includes wrapper logic. If Windows quoting is awkward, create a temporary PowerShell runner with an argument array, run it, then remove the runner.

Common local tool path for this workspace:

```text
C:\Users\AveryOperatorContrac\OneDrive - Contoso Energy\Documents\Microsoft-Win32-Content-Prep-Tool-1.8.7\IntuneWinAppUtil.exe
```

If that path is missing, search for `IntuneWinAppUtil.exe` before asking the user.

## Validation

Before packaging:

1. Validate all generated PowerShell scripts with the PowerShell parser.
2. Confirm the folder layout and installer are present.
3. **MANDATORY before any Intune upload or MAA request** (standing directive, 2026-08-18): run the
   full lifecycle in SYSTEM context on a test endpoint via remote command execution — use the
   screenconnect-remote-diagnostics skill, whose command channel runs as SYSTEM, the same context
   Intune uses. Stage the exact package-relative file topology, then prove end to end:
   `install -> detection detects -> re-run install exits 0 (idempotent) -> uninstall -> detection reports absent`.
   Read the wrapper transcripts and verify the endpoint's REAL registered state (ARP DisplayName,
   InstallLocation, Uninstall/QuietUninstallString) rather than assuming vendor naming — DWG
   TrueView 2027 registered an "Autodesk "-prefixed DisplayName, a parent-folder InstallLocation,
   and an unquoted UninstallString, and only a live SYSTEM run exposes that; skipping this test
   shipped a package that installed fine but reported Failed in Company Portal. Target a
   designated test machine (confirm the target with the user if none is designated); never a
   random user's endpoint. The standing directive covers the test-endpoint install/uninstall —
   no per-run approval needed once the target machine is agreed.
   PsExec locally is an acceptable fallback only when no test endpoint is reachable, and the
   remote SYSTEM test then happens before broadening the assignment.
   Run two separate lifecycles when partial installs matter: a clean install/detect/idempotent/uninstall
   cycle, then a deliberately incomplete same-version install followed by the production repair branch.
   Prove preservation with a database/file sentinel plus service path/account, configuration hashes,
   listener ownership, credential behavior, and the pre-existing application baseline.
   InstallBuilder launchers can exit before detached cleanup finishes, and descendants can inherit
   anonymous stdout/stderr pipes. Capture output to files, bound every wait, refresh process state before
   reading exit codes, and require the current vendor log's final exit marker plus stable postconditions.
   On timeout, retain the protected option/log directory while the vendor process is alive; remove test
   data only when the preflight proved it absent and an ownership marker/hash authorizes cleanup.
   For a wrapper that queries existing packages, registry values, or services before installing,
   explicitly test the zero-result branch. An empty command-substitution result is `$null`; do not
   bind it to a `[Parameter(Mandatory)][object[]]` parameter. Allow null/empty input, return no
   pipeline output for no candidates, and use a mocked first-install test to prove the wrapper reaches
   the installer when the managed state is absent.
   For replacement packages, also test the real upgrade path from the version already deployed in
   the environment; a cleanup-only test against a current version does not prove the older deployed
   version can repair, patch, or reconfigure in place.
   After a Retry return code such as 1618 reaches Intune Management Extension's retry limit, the
   app can enter GRS cooldown; normal syncs can then log "the app will not be enforced" until GRS
   expires. Inspect AppActionProcessor.log/AppWorkload.log before assuming a closed app will retry
   immediately.
   For a provisioned MSIX on an Entra-joined endpoint, verify active-user registration from SYSTEM
   with `Get-AppxPackage -AllUsers`, then match
   `PackageUserInformation.UserSecurityId.Sid` to the exact target SID and require
   `InstallState=Installed`, package `Status=Ok`, and the expected version. Do not rely on
   `Get-AppxPackage -User <Entra SID>`: Windows PowerShell can reject a valid `S-1-12-1` SID with
   `No valid SID could be determined` (verified 2026-08-19). If immediate registration is required,
   run `Add-AppxPackage` in an unelevated interactive task pinned to the exact logged-on account and
   SID; have the worker independently validate its runtime identity and signed payload, and do not
   launch the app.
4. Inspect install/uninstall logs when behavior differs from Settings or Installed Apps UI; those views can be stale.
5. Re-run packaging only after scripts are finalized.

Use `rg`, `reg query`, `dir`, and `Test-Path` to inspect evidence. Be careful with quoted paths in `cmd`; use PowerShell `-File` or temporary runner scripts when command-line quoting becomes unreliable.

## Intune Settings

Report these settings with the finished package:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install-<App>.ps1
```

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-<App>.ps1
```

Use:

- Install behavior: `System` unless intentionally per-user.
- Device restart behavior: based on app needs; accept `3010` as soft reboot.
- Detection: upload parent `Detection.ps1`.
- Detection script host: 64-bit PowerShell where available.
- `allowAvailableUninstall`: leave it **off** whenever the uninstall command removes more than this
  one app. Suite installers are the usual trap - an uninstall switch such as `/removeall` can strip
  every product and every version the vendor ever installed, and with an *Available* assignment plus
  user-initiated uninstall enabled, any end user can trigger that from Company Portal with one click
  (verified 2026-08-05). Turn it on only once the uninstall is proven to scope to the packaged app.
  Also turn it off when the uninstall is a deliberate no-op, so the button cannot generate
  no-effect support calls.

## Company Portal Logo and Upload

Uploading or changing an Intune app is production-impacting. Before any Graph write, obtain explicit
user approval to upload AND complete the mandatory SYSTEM-context lifecycle test (Validation item 3);
approval to package alone is not approval to publish. Also get an explicit deployment intent: a
separately named test app or an in-place update to one exact existing app ID. Never infer an
existing-app update from the package name, matching display name, or a generic request to upload.
When the user wants testing or has not explicitly identified a production app, publish a separately named,
unassigned test app.

Assignment defaults (standing directives, 2026-08-18):

- **First upload of a new app: assign Available to the security group `AZ-TEST-EUC-Users` only**
  (objectId `bbe86257-c03b-2651-572c-5c438cc1923c`, verified 2026-08-18) unless the user states a
  different target. Broader targets (more groups, All Users) come later, when the user asks after
  test-group validation. Do not create Required assignments unless explicitly requested.
- **Every assignment sets `notifications: 'hideAll'`** in `win32LobAppAssignmentSettings` — end
  users see no install/restart toasts. Granular additive body (MAA-gated; file it per the
  acquire-graph-token identity rules):

  ```json
  {
    "@odata.type": "#microsoft.graph.mobileAppAssignment",
    "intent": "available",
    "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget",
                "groupId": "bbe86257-c03b-2651-572c-5c438cc1923c" },
    "settings": { "@odata.type": "#microsoft.graph.win32LobAppAssignmentSettings",
                  "notifications": "hideAll" }
  }
  ```

1. Prefer a vendor-supplied PNG that is already inside the signed installer or an official vendor source.
   Do not generate or substitute a synthetic logo. Inspect the file before upload and retain it beside the
   versioned package as a reusable artifact.
   When no loose image ships with the media, extract the icon from a signed vendor binary rather than
   downloading one. `Icon.ExtractAssociatedIcon` returns only 32x32; enumerate the `RT_ICON` resources
   (`LoadLibraryEx` with `LOAD_LIBRARY_AS_DATAFILE` + `EnumResourceNames`) and take the largest. A
   256x256 entry is usually a 32bpp DIB, not a PNG: 40-byte `BITMAPINFOHEADER`, then bottom-up BGRA
   pixels, then an AND mask. Copying those rows in reverse into a `Format32bppArgb` bitmap needs no
   channel swap, since both are BGRA in memory. Verify the result by sampling the same pixels from
   `ExtractAssociatedIcon`; matching values prove the colors are right rather than byte-swapped.
2. Confirm the package, setup script, detection script, install/uninstall commands, display metadata, icon,
   and deployment intent before publishing. For a script-wrapped EXE/MSIX, do not invent MSI metadata.
3. Use `scripts/Publish-IntuneWin32App.ps1` for a Graph upload. It parses the `.intunewin`, uploads the
   encrypted payload as Azure block-blob chunks followed by a block list, creates a custom detection rule,
   attaches an optional PNG, and waits for `published`. Do not send a one-shot blob PUT: Azure can accept it
   while Intune later rejects the content as `commitFileFailed`. Pass `-DeploymentIntent CreateSeparateTest`
   with no `-ExistingAppId` for a separate test app, or `-DeploymentIntent UpdateExisting` plus the exact
   `-ExistingAppId` only after the user specifically approves an in-place update. It refuses duplicate display
   names and writes a summary JSON; it intentionally creates no assignments.
   When setting Intune's visible Win32 version, pass both `-Version '<version>'` and
   `-GraphApiVersion beta`. The `displayVersion` property is beta-only (verified 2026-07-28); the publisher
   refuses `-Version` with v1.0 so the value cannot be silently omitted.
   On Windows PowerShell 5.1, load `System.Net.Http` before constructing the Azure block uploader's
   `HttpClient`. If a run creates a content version or placeholder but fails before `commitFileSuccess`, leave
   that draft inactive and inspect its file state before retrying; never activate an uncommitted version.
   If the Graph PowerShell authentication module cannot load in a noninteractive host, use a narrow delegated
   REST runner only after a GET verifies the exact target app, and preserve the publisher's MAA headers,
   Azure block-upload/commit sequence, summary, and assignment safeguards.
4. Keep the `-Justification` text **under 1024 decoded characters**. Over that, the activating PATCH
   fails `400 BadRequest` ("Decoded content of 'x-msft-approval-justification' header must be no greater
   than 1024 characters") and files no approval request — but the app, content version, and committed
   content have already been created by then, leaving a `notPublished` draft. Recover by resuming that
   validated version with `-ActivateContentVersionId` (which requires `-ExistingAppId`, hence
   `-DeploymentIntent UpdateExisting`) rather than re-uploading; confirm `uploadState=commitFileSuccess`
   and zero assignments first. Verified 2026-07-29. See the acquire-graph-token skill for the header rules.
   **Always pass `-DelegatedGraph` so the MAA request files as `z_admin`, not the app identity**
   (audit directive verified 2026-08-18: app-filed requests show a service principal as "Requested
   by" and let the initiating admin self-approve; see the acquire-graph-token skill's identity
   rules). If the delegated store is dead, remint per that skill before publishing.
   The publisher authenticates by bridging an existing delegated token when `Get-MgContext` is cold, so it
   runs in a noninteractive host; it falls back to interactive sign-in only if no valid token file is found.
   Let any Intune Multi Admin Approval request remain pending for an approver. Report its request ID and
   stop rather than retrying or bypassing the gate. A `409 Conflict` saying that an active approval request
   already exists is also a pending MAA state: query `operationApprovalRequests` for `needsApproval`, match
   the app `payloadId`, and report its ID and expiration instead of treating it as an upload failure.
   Once it is approved, validate its target app ID, name, operation, and committed content version, then
   complete it by resubmitting the original Graph-native write with `x-msft-approval-code`. Do not replay the
   approval record's serialized `patchPayload` directly: it can contain legacy OData type names that the v1.0
   endpoint rejects. Verify the request reaches `completed`, the intended content version is published, and
   assignments remain unchanged.
5. For an existing app, pass its Intune app ID so the publisher preserves assignments. It uploads and validates
   a new content version before one final PATCH activates both content and metadata. If any version reaches
   `commitFileFailed`, leave it uncommitted, do not switch `committedContentVersion`, and inspect the summary
   before attempting a corrected new content version.
   If a session ends after `commitFileSuccess`, resume that validated version with
   `-ActivateContentVersionId` instead of uploading it again.
   For `UpdateExisting`, the publisher omits the create-time-only `installExperience` object; do not
   pass `-InstallRunAsAccount`. Verify the existing run context/restart behavior before and after.
   Use `-ReturnCodeProfile Strict` when 1707 must not count as success, and
   `-AvailableUninstallPolicy Disable` when Company Portal uninstall must be hidden.
6. If a request was accidentally submitted against the wrong existing app, cancel its pending MAA record with
   `operationApprovalRequests/cancelMyRequest` before creating the separate test app. Verify the production
   app's `committedContentVersion` and assignments are unchanged before proceeding.

See `references/intune-win32-publishing.md` for the invocation pattern and Graph safeguards.

In the final response, provide clickable paths to the scripts, detection file, and `.intunewin`, plus any caveats such as required elevation, per-user cleanup behavior, or external patching assumptions.

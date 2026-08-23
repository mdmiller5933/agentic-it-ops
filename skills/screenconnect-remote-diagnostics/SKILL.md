---
name: screenconnect-remote-diagnostics
description: Investigate or troubleshoot a company-managed endpoint through ConnectWise ScreenConnect / Control, including remote diagnostics, command output retrieval, and approved file staging or transfer. Use when the user asks to check on, diagnose, run commands, send files, stage installers, or remediate a remote device, or when Rapid7, Automox, Freshservice, Intune, or another system identifies a device issue. Require explicit approval before remediation or user-impacting changes. For an interactive shell or quick SSH command on a reachable endpoint, prefer the ssh-access skill.
---

# ScreenConnect Remote Diagnostics

## Overview

Use ScreenConnect as an authorized, logged remote diagnostics channel for endpoint-specific troubleshooting. Prefer read-only PowerShell evidence first; require explicit approval before making endpoint changes.

## Required Reference

When working in `C:\automox-mcp-main`, read the shareable runbook before first use in a session, for a new device/system context, or for complex/bulk work:

```text
C:\automox-mcp-main\docs\screenconnect-api-remote-diagnostics-runbook.md
```

For a simple follow-up in the same conversation after the runbook has already been read, use the fast path below instead of rereading the full runbook.

If the repo runbook is unavailable, follow this skill's core workflow and ask for the env variable names needed to access ScreenConnect. Prefer Keeper Secrets Manager over plaintext env files when available. Never ask the user to paste the RESTful API Manager secret into chat.

Keeper setup notes:

```text
C:\automox-mcp-main\docs\keeper-secrets-codex-setup.md
```

## Operator Browser Context

For interactive ScreenConnect Host UI work, use the user's admin Microsoft Edge workspace/profile. Do not assume the regular `avery.operator@contoso.com` Edge workspace is signed in to ScreenConnect or authorized for host actions. REST API calls should use the configured environment variables and are not tied to the browser workspace.

## Core Workflow

1. Confirm the operational reason: Freshservice ticket, Rapid7 finding, Automox issue, Intune device issue, change, or incident.
2. Identify the device by name, serial, user, or asset record.
3. Query ScreenConnect Access sessions and disambiguate the target.
4. Run read-only diagnostics first.
5. Summarize evidence with timestamps and target identifiers.
6. Ask for explicit approval before remediation, service restarts, reboots, registry edits, installs, uninstalls, file deletion, policy changes, or permission changes.
7. Verify fixed state in the originating system and record what changed.

## ScreenConnect API Pattern

Use the RESTful API Manager endpoint:

```text
{BaseUri}/App_Extensions/{ExtensionId}/Service.ashx/{Method}
```

Headers include `Content-Type: application/json`, `Accept: application/json`, `CTRLAuthHeader`, and `Origin`. The request body is a JSON array of method arguments.

Known working methods:

- `GetSessionsByFilter`
- `SendCommandToSession`
- `GetReport` for ScreenConnect reports/session events. Verified in the Contoso tenant on 2026-06-30 by retrieving `RanCommand` output for read-only diagnostics.

Treat `SendCommandToSession` as a queue operation. It returns no value; retrieve command output afterward from `SessionEvent` report data with `GetReport`. Do not expect the report row to exist immediately. Wait a few seconds, then poll repeatedly for the target `SessionID` and marker until the `RanCommand` event appears or an appropriate timeout expires. Use a unique marker in the command output and query `ReportType = "SessionEvent"` for `RanCommand`/`QueuedCommand` events matching the target `SessionID` and marker. Redact secrets and unrelated user data before sharing output.

### Windows shell-launch fallback

Verified 2026-08-06: if direct PowerShell and `cmd.exe` launches repeatedly fail with Windows
`os error 1223`, continue through an available persistent Node-backed JavaScript runtime instead
of retrying shells. Resolve the ScreenConnect KSM record through the retrieve-keeper-secret
procedure into memory, with child-process output captured rather than inherited, parse its
`KEY=value` notes without printing them, and call the same RESTful API Manager endpoints with
`fetch`. Keep the authentication secret only in memory and emit only sanitized session projections
or command results. The normal read-only-first and approval gates still apply; this is a transport
fallback, not broader authorization.

## Command Payload Defaults

ScreenConnect commands default to `cmd.exe`, a short timeout, and truncated output. For silent diagnostics, prepend hashbang parameters that fit the payload. For PowerShell diagnostics, normally start with:

```powershell
#!ps
#maxlength=100000
#timeout=90000
```

Use a longer timeout for slow inventory, installer, or scan checks, and a smaller `#maxlength` for narrowly scoped probes. Keep the command output bounded and avoid interactive prompts. For PowerShell, prefer returning structured objects as JSON instead of formatted tables or free text. Cast PowerShell enum values, such as service `Status` and `StartType`, to strings before `ConvertTo-Json` so results say `Running` instead of `4`.

Before `ConvertTo-Json`, project CIM/WMI objects to the few scalar fields needed for the diagnosis. Do not serialize raw CIM instances, nested `CimClass` metadata, certificates, or registry provider objects: one such value can consume the entire ScreenConnect `#maxlength`, omit the ending marker, and make a successful command look truncated or unparseable.

For log or event excerpts, convert every returned value to an explicit `[string]`, cap both line length and line count, and collect one evidence category per command. With Contoso's `run-screenconnect-powershell-file.mjs` helper (verified 2026-07-27), the endpoint command is killed after 120000 milliseconds and command output is limited to 90000 characters. Avoid combining broad `Get-AppxPackage -AllUsers`, unfiltered `Get-WinEvent`, and long log tails in one collection; retrieve the application wrapper/DISM log first, then issue a focused follow-up only if needed.

On Windows PowerShell 5.1, convert generic collections explicitly before embedding them in result objects: use `$list.ToArray()` for `System.Collections.Generic.List[T]`. Wrapping a generic list as `@($list)` can throw `Argument types do not match` during result construction even after the endpoint actions have already succeeded.

```powershell
$result = [ordered]@{
  ComputerName = $env:COMPUTERNAME
  WhoAmI = (whoami)
  Checks = @()
  Errors = @()
}
$result | ConvertTo-Json -Depth 6 -Compress
```

Wrap JSON with the unique command marker so `GetReport` parsing can extract the intended result cleanly.

## Fast Path for Simple Approved Actions

For one-host, low-blast-radius actions that the user has already approved, such as starting a service, checking a registry value, or collecting a narrow proof item, do not create a new one-off script or run a broad diagnostic suite by default.

Use the lean path:

1. Reuse the known `SessionID` from the current conversation when available; otherwise do one exact `GetSessionsByFilter` lookup.
2. Send one minimal `#!ps` payload with a short timeout, usually `#timeout=30000` to `#timeout=90000` and `#maxlength=20000` to `#maxlength=100000`.
3. Include before/action/after fields in the same JSON result.
4. Wait briefly after `SendCommandToSession`, then poll `GetReport` for that marker only. For quick probes, start around 2-5 seconds and poll every 2-5 seconds for about 30-60 seconds; for installs, scans, inventory, or repairs, use longer intervals and a timeout aligned to the command's `#timeout`.
5. Summarize the result directly. Write a report only for bulk work, security-sensitive remediation, unclear failures, or when the user asks for an artifact.
6. Run a full follow-up diagnostic only when the after-state is not clean, the user asks for broader confirmation, or the originating system needs separate verification.

For Windows Update cadence checks, start with bounded native queries: use `schtasks.exe /Query /TN "\\Microsoft\\Windows\\UpdateOrchestrator\\Schedule Scan" /V /FO LIST` for the last and next scan task times, and `wevtutil.exe qe Microsoft-Windows-WindowsUpdateClient/Operational /c:20 /rd:true /f:text` for recent completed scan/download events. Avoid combining a broad `Get-WinEvent` query, `Get-HotFix`, service inventory, and log tails in one short-timeout payload; that bundle can exceed 30-60 seconds and return only the beginning marker. Add categories incrementally after the narrow probe succeeds.

## File Transfer and Tool Staging

ScreenConnect has built-in Host UI paths for file movement and tool delivery, including File Transfer/File Manager, Backstage File Manager, and the shared toolbox. Use the admin browser profile described above for interactive Host UI work. As of 2026-07-03, the Contoso RESTful API Manager path is verified for session lookup, command queueing, and report retrieval; it is not yet verified for direct file upload or file-transfer actions.

When a user asks to send, stage, or run a file:

1. Treat file transfer, installer staging, and tool execution as state-changing unless it is clearly a read-only collection to an approved location.
2. Ask explicit approval for the target host, source file or URL, destination path, and whether the file should only be staged or also executed.
3. Prefer the built-in ScreenConnect Host UI transfer, Backstage File Manager, or approved shared toolbox for operator-driven transfer.
4. If Host UI transfer is unavailable and the file is from a trusted URL or internal package source, use `SendCommandToSession` only after approval to download/stage it on the endpoint, verify hash/signature when practical, and retrieve output with `GetReport`.
5. Stage IT artifacts under a controlled path such as `C:\ProgramData\Contoso\...`; avoid user profiles and personal folders unless the task specifically requires them.
6. Record the file name, source, destination, hash when available, target session, approval, and any execution command in the evidence summary.

## Long-Running Work and Per-User Installs

Verified 2026-08-07 installing Spotify for the logged-on user on `WKS-SN0116`.

**The command channel hard-kills at 120000 ms.** A payload that overruns returns exit code
`-536870873` with completely empty `StdOut` and empty `StdErr` — it looks like a parse failure or a
silent no-op, not a timeout. A 100 MB download is already enough to trip it. Never put a download,
an installer, a scan, or a repair directly in the command payload.

**Decouple with a SYSTEM-owned scheduled task.** A child process started with `Start-Process` can
die with the command channel; a Task Scheduler job cannot, because the service owns it. Pattern:

1. **Launch command (returns in seconds):** write a worker `.ps1` under `C:\ProgramData\Contoso\<job>\`,
   register a task as `-UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest`, `Start-ScheduledTask`,
   and return. `LastTaskResult` `267009` (`0x41301`) means *currently running* — that is success here.
2. **Worker (as SYSTEM, unbounded):** download → verify Authenticode → do the work → write progress
   to a `status.json` after every phase, so a poll can always tell what stage it reached.
3. **Poll command:** read `status.json` plus the real proof artifact. Keep polling read-only.
4. **Cleanup command:** unregister every task and delete the staging directory, then re-assert
   `TasksRemaining` is empty and the proof artifact still exists. Do not leave the orchestrator task
   behind — it survives its own run in state `Ready`.

**Per-user installers must run as the user, unelevated.** Spotify's `SpotifyFullSetup.exe` installs
to `%APPDATA%\Spotify` and *refuses to run elevated*, so a SYSTEM command, an Automox worklet, and a
System-context Intune Win32 app all either fail or install into the SYSTEM profile. Have the SYSTEM
worker register a second task for the target user:

```powershell
New-ScheduledTaskPrincipal -UserId 'AzureAD\<SamName>' -LogonType Interactive -RunLevel Limited
```

- `RunLevel Limited` is required, not cosmetic — `Highest` reintroduces the elevation refusal.
- Try the `AzureAD\<name>` form first and fall back to the raw SID; Entra accounts accept either
  inconsistently. Get both from `Win32_UserProfile` + `quser` in the pre-flight.
- `LogonType Interactive` only runs while that user is logged on. Confirm the session first:
  `quser` for session id/state, and the owner of `explorer.exe` for the real interactive desktop user.
- A non-admin worker **cannot write** into a SYSTEM-created `C:\ProgramData\Contoso\...` folder
  (inherited ACL is Read & Execute for Users). Keep all status writing in the SYSTEM worker, or
  target the user's own `%LOCALAPPDATA%`.
- Verify a per-user install in the user's hive, not HKLM:
  `HKEY_USERS\<SID>\Software\Microsoft\Windows\CurrentVersion\Uninstall\...`, plus the Start Menu
  `.lnk` under their profile so they can actually launch it.
- Expect the app to auto-launch even with a silent switch. Say so when reporting, rather than
  claiming the install was invisible to the user.

**Store-based delivery is not an option on this fleet.** `HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore\RemoveWindowsStore = 1`,
so "let the user install it from the Microsoft Store" is dead on arrival. Check that key before
proposing self-service. See the `windows-store-blocked-fleetwide` memory note.

### SYSTEM migration-worker guardrails

Verified 2026-08-15 during a side-by-side PostgreSQL major-version migration:

- Assume the endpoint worker is Windows PowerShell 5.1. After `WaitForExit()`, call
  `$process.Refresh()` before reading `ExitCode`; null-guard redirected output before `.Trim()`.
  Empty command output can be a legitimate result, such as no custom tablespaces.
- For an interactive-user scheduled task, the Windows PowerShell ScheduledTasks enum is
  `-LogonType Interactive` with `-RunLevel Limited`; `InteractiveToken` is not a valid enum value.
- Put temporary database trust/authentication changes in a `finally`-protected rollback path.
  Verify those rules are absent at the end, even when restore or validation fails.
- Treat rollback as successful only after the primary service, every discovered dependent service,
  original listeners, and protected data all match the pre-flight. A database service alone can be
  healthy while its consuming application services remain stopped or point at the wrong port.
- For a major-version cutover, keep both logical backups and a stopped physical copy of the old
  cluster until the application owner validates the migrated workload. Disable rather than delete
  the old service during the rollback window.

## Safety Rules

- Keep secrets out of chat, logs, reports, and committed files.
- Use read-only diagnostics by default.
- Do not unlock or authenticate to a user's desktop.
- Do not collect credentials, cookies, tokens, browser data, private keys, or unrelated personal files.
- Do not disable security tools, delete logs, or conceal activity.
- Do not run broad commands across many devices unless the user explicitly requests a bulk action and approves the scope.
- Prefer ticket/change correlation for every command.
- Report command intent, target, and risk before state-changing actions.

## Recommended Command Categories

Read-only examples:

- `hostname`, `whoami`, uptime, OS version, serial.
- Service/process status for Rapid7, Automox, Intune Management Extension, Defender, Cato, CrowdStrike, etc.
- Installed app version checks.
- Relevant event log or vendor log excerpts.
- Network and DNS checks.
- Pending reboot checks.

Approval-required examples:

- Restart service, repair agent, clear cache, install, uninstall, patch, reboot.
- Registry, firewall, local admin, scheduled task, or security setting changes.
- Running remediation from Automox, Intune, or another management plane.

## Evidence Output

When done, summarize the machine, session, command category, result, and any next action. Include enough detail for a Freshservice ticket or change note, but redact secrets and unrelated user data.

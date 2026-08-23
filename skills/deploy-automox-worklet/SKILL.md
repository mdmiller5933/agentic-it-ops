---
name: deploy-automox-worklet
description: Author and deploy a custom Automox worklet (evaluation + remediation PowerShell pair) and scope it to specific devices, including devices belonging to an Entra/Azure AD group. Use when the user asks to create or push an Automox worklet, build a remediation policy, push a registry or config fix to a set of devices via Automox, scope a worklet to an Entra group or saved search, or fleet-remediate endpoints. Covers the evaluation exit-code contract (0=compliant, 1=remediate), policy_type_name "custom", the device_filters 10-value cap, saved-search scoping via assign_policies_to_saved_search, the Entra-group to Intune-device to Automox-device-by-serial mapping, and controlled per-device push with remediateServer. For Automox patching/compliance reads use the Automox MCP tools directly; this skill is specifically for building and targeting remediation worklets.
---

# Deploy Automox Worklet

Build and target a custom Automox worklet. Creating, assigning, or executing a policy is production — get explicit approval first. Use the Automox MCP tools (org is auto-scoped).

## 1. Write the two scripts

A worklet is a `custom` policy with an `evaluation_code` and a `remediation_code` (PowerShell, run as SYSTEM). **Do NOT assume 64-bit:** the Automox agent launches the worklet PowerShell **32-bit** (confirmed `[Environment]::Is64BitProcess` = false, agent 2.5.70, 2026-07-10), so `HKLM:\SOFTWARE\...` / `HKU\<sid>\SOFTWARE\...` provider paths are WOW6432Node-redirected. A Sysnative self-relaunch does NOT help (the script is fed inline, so `$PSCommandPath` is empty) — use the explicit 64-bit registry view instead (below).

- **Evaluation contract:** exit `0` = compliant (no action); non-zero (use `1`) = run remediation.
- **An unscheduled Worklet still evaluates on the agent refresh/scan cadence.** `schedule_days=0` prevents scheduled remediation; it does not make evaluation code dormant. Keep evaluation side-effect-free: use console output, not unbounded `Add-Content` calls or user-visible artifacts under `C:\Temp`. If persistent endpoint evidence is essential, write a bounded/rotated log under `C:\ProgramData\Automox\Logs` and include cleanup/retention logic.
- **Every evaluation branch must end in an explicit `exit`.** A PowerShell script that falls off the end returns 0, so an evaluation that only `Write-Host`s its verdict reports **every device compliant on every run** and the remediation never executes — while the console shows a green 100%-compliant policy and per-device outcomes of `remediation_not_applicable`, never `failed`. This fails completely silently; nothing in the dashboard flags it. Verified 2026-07-27 on policy 500888 "Device rename to WKS-{serialname}": 380 compliant / 0 noncompliant, 90 runs over 99 days, zero renames actually performed. **When a worklet reports high compliance but the real-world state has not changed, read the `evaluation_code` for a missing `exit` before investigating anything else**, and confirm against ground truth from the system that owns the state (Intune/Entra/registry) rather than trusting the Automox compliance number.
- **Self-gate in evaluation** so irrelevant or already-fixed devices exit 0 and no-op. This makes the worklet idempotent and safe to leave on a recurring schedule. Gate out known-impossible devices too (missing/placeholder BIOS serial, a computed name over the 15-char Windows limit) so they do not churn as permanent failures.
- **Schedule for when the fleet is actually on.** A daily `00:00` schedule mostly produces `not_included / Device was Offline` for laptops; the working Contoso pattern is 12:00 on weekdays.
- **Remediation:** do only the change; do NOT reboot or restart services unless the user approves (that disrupts the logged-in user). State that config takes effect on next reboot.
- **ALL registry ops (detect AND remediate) — open the 64-bit view explicitly.** Because the worklet host is 32-bit, `Test-Path`/`Remove-Item`/`Get-ItemProperty` on `HKLM:\SOFTWARE\...` silently hit WOW6432Node — so a removal worklet can report a key deleted (`Remove-Item ...; -not (Test-Path ...)` → true) while the real native-hive key survives untouched, and detection can miss present keys. Use `$hklm=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)` (and `::Users` for HKU), then `$hklm.OpenSubKey($sub)` to test and `$hklm.DeleteSubKeyTree($sub)` to remove. Same trap on the Intune 32-bit install host — see the intune-win32-registry-wow6432-redirection memory.
- **Per-user HKCU keys (e.g. Office `HKCU\Software\Microsoft\Office\16.0\...`):** the worklet runs as SYSTEM, so a plain `HKCU:` write lands in the SYSTEM profile, not the logged-on user. Resolve the interactive user's SID from the `explorer.exe` process owner and write through `HKEY_USERS`: `$o=Invoke-CimMethod (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'"|select -First 1) -MethodName GetOwner; $sid=(New-Object Security.Principal.NTAccount($o.Domain,$o.User)).Translate([Security.Principal.SecurityIdentifier]).Value; $p="Registry::HKEY_USERS\$sid\Software\..."`. If no `explorer.exe`, no interactive session — exit 0 / no-op (a scheduled recurring worklet catches each user at next login). Effective on next app restart, no reboot. Example: the purview-sensitivity-labeling-rollout memory (policy 501554).

- **Removing a taskbar pin — never just delete the `.lnk` from SYSTEM.** Deleting `...\User Pinned\TaskBar\X.lnk` leaves the pin in the user's `HKCU\...\Explorer\Taskband\Favorites` blob, so explorer shows a blank "white paper" ghost icon. Invoke the shell **"Unpin from taskbar"** verb (`(New-Object -ComObject Shell.Application).Namespace($tbFolder).ParseName('X.lnk').Verbs()` → `.DoIt()`) **in the user's session** — it rewrites the blob. To run in-session from a SYSTEM worklet: stage a small script, `Register-ScheduledTask -Principal (New-ScheduledTaskPrincipal -UserId <interactiveUser> -LogonType Interactive -RunLevel Limited)` with a **near-future time trigger** (`New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15)`), then wait and clean up. `Start-ScheduledTask` on such a task does NOT launch it (LastRunTime stays blank) — the time trigger does. Example: the lenovo-ai-now-removal-worklet memory.

- **Anything the USER must see (toast/notification/UI) cannot be done from the worklet directly** —
  and this fails silently, reporting success. A worklet runs as SYSTEM in session 0, where `HKCU:`
  is the SYSTEM profile and a WinRT toast is delivered to nobody. Watch for it when porting a tool
  that ran in a user context (an Intune remediation with `runAsAccount=user`), because the code
  looks correct and simply reaches no one. Also check cadence before porting: a group's
  `refresh_interval` (`list_server_groups`, MINUTES, commonly 240) is the *fastest* a worklet can
  re-evaluate, so any interval shorter than that cannot be driven by the worklet at all.
  Fix both at once — have the worklet **install and maintain a scheduled task** that carries the
  real logic and runs at the required interval in the user's session:
  `New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited` (BUILTIN\Users **by SID**,
  locale-independent; gives `LogonType=Group`, so it runs for whichever member is logged on).
  Hourly forever = a `-Daily` trigger whose `.Repetition` is taken from a throwaway
  `-Once ... -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 55)`
  trigger. Build the action's `powershell.exe` path as a LITERAL `System32` string — a string is
  not WOW64-redirected (only filesystem access is), and the 64-bit Task Scheduler resolves it to
  real System32 at run time. Evaluation then only checks "payload present, version current, task
  registered and enabled"; stamp a version file next to the payload and exit 1 on drift, which is
  how you ship an update. Embed the payload as base64 in the remediation and verify the round trip
  at build time. Note `Start-ScheduledTask` against a Group-principal task returns *Access is
  denied* for an unelevated user — that is expected; the time trigger drives it, so prove the task
  works by reading `LastTaskResult` after its first scheduled fire, not by starting it by hand.
- **A notification worklet needs corroborated triggers, or it nags people for nothing.** Gate on the
  specific subsystem's own signal (e.g. Windows Update's `RebootRequired`), not a generic probe, and
  require a second opinion before speaking — an app installer that leaves `PendingFileRenameOperations`
  behind is not a Windows Update restart. If the claim cannot be substantiated, stay silent rather
  than emitting generic wording. Put the whole decision in ONE pure function taking observed state as
  parameters, add a test that dot-sources the real payload (guard the body with an env-var hook so it
  loads without executing) and asserts a truth table — a gate you have not tested is a gate you are
  guessing about, and every false positive trains users to ignore the real warning.

Model a new worklet on an existing `custom` policy: read one with `policy_detail` to copy the config shape.

## 2. Resolve scope

Match devices by **serial**, never hostname (hostnames differ across Intune, ScreenConnect, and Automox).

- **From an Entra/Azure AD group:** confirm Graph auth (`scripts\intune-auth-test.cmd` in the automox-mcp repo; see the microsoft-graph-intune-access-runbook and the graph-mcp-intune-access-options memory). Query `groups/{id}/transitiveMembers/microsoft.graph.user`, then per user `deviceManagement/managedDevices?$filter=userPrincipalName eq '<upn>'` for `deviceName, serialNumber, operatingSystem`. Keep Windows, de-dupe by serial.
- Map serials to Automox with `advanced_device_search` (`{scope:DEVICE, field:serialNumber, operator:IN, values:[...]}`). Expect some devices missing from Automox (unenrolled, or over the license cap — see the automox-api-traps memory §1, cap is 480 now) and some duplicate agent records; report the gaps.

## 3. Create the policy

`apply_policy_changes` with `policy_type_name:"custom"`, `configuration:{os_family, evaluation_code, remediation_code}`, and a friendly `schedule:{days:["weekdays"],time:"12:00"}`. Run `preview:true` first, then `preview:false`. **Preview does NOT enforce all API limits** (see the cap below), so a clean preview is not proof the real call will succeed.

### Creating a policy over direct REST (also: read-only audit worklets)

`POST /api/policies?o={org}` returns **201 with an empty body** — no id. Locate the new policy by
name afterwards rather than parsing the response. Prefer REST over the MCP tool when the scripts
are long: read the `.ps1` files off disk verbatim so the PowerShell cannot be mangled by JSON
escaping, and it becomes reviewable and re-deployable. Three traps (verified 2026-08-05):

- **`configuration` must carry the full notify/reboot flag set**, not just
  `{os_family, evaluation_code, remediation_code}`. Omitting them fails `500 "An unexpected error
  occurred"` with no field named. Copy the shape off a working `custom` policy
  (`GET /api/policies/{id}`) — it needs `auto_reboot, notify_user, notify_reboot_user,
  missed_patch_window, device_filters_enabled, install_deferral_enabled,
  notify_deferred_reboot_user, reboot_do_not_disturb_honored, install_do_not_disturb_honored,
  pending_reboot_deferral_enabled, notify_deferred_reboot_user_auto_deferral_enabled`. All false
  is what makes a worklet silent; `notify_user:false` is the one that suppresses the end-user prompt.
- **Bit 0 is UNUSED in `schedule_jarvis_of_month` and `schedule_months`.** Every week = `62`
  (not 31), all twelve months = `8190` (not 4095); the intuitive all-bits-set values are shifted
  by one and rejected with the same opaque 500. `schedule_days` 62 = Mon–Fri as normal.
- **Automox strips the trailing newline when storing script bodies**, so a byte compare of stored
  vs on-disk code is off by exactly one and reads as truncation. Classify that case explicitly
  before chasing it, and do verify integrity — it is the only proof the upload was not mangled.

**Read-only audit worklet pattern.** To measure endpoint state without changing it, put the
detection in `evaluation_code` (exit 1 when the condition is present) and make `remediation_code`
a *reporter* that only re-enumerates and prints — no write/add/remove/set call. The compliance
percentage then IS the answer, per-device detail lands in `policy_run_results`, and nothing is ever
modified. Gate the deploy on a regex that rejects mutating cmdlets, and strip PowerShell comments
before that scan or prose promising "does not call Remove-*" trips its own guard. Remember
`remediateServer` skips evaluation, so only a **scheduled** run exercises the exit codes.

### Updating a policy over direct REST (when the MCP tools are unavailable)

Fetch-modify-PUT works: `GET /api/policies/{id}?o={org}` then `PUT` the same URL with body fields `name, policy_type_name, organization_id, schedule_days, schedule_jarvis_of_month, schedule_months, schedule_time, notes, server_groups, configuration`. Two traps (verified 2026-08-04 on policies 502220/500888):

- **The name-uniqueness validator compares against ALL policies INCLUDING the one being updated.** A PUT that keeps the policy's current `name` fails `400 {"errors":{"name":["A policy with this name already exists"]}}`. Every PUT must change `name` — even a one-character tweak passes.
- **`status` is read-only/derived** — `PUT` with `status:'inactive'` is silently ignored (the write succeeds, status stays `active`). To retire a policy, make it inert instead: `server_groups: []` plus `schedule_days/schedule_jarvis_of_month/schedule_months: 0`. With zero assigned devices even a manual `remediateAll`/`remediateServer` has nothing to hit, and evaluation stops running fleet-wide. Rename it `zz-RETIRED ...` and document why in `notes`.

## 4. Target the devices

- **<= 10 devices:** `configuration.device_filters:[{op:"in",field:"serial_number",value:[...]}]` + `device_filters_enabled:true` + `server_groups` containing those devices (the filter applies WITHIN the assigned groups).
- **> 10 devices:** the `device_filters` value list is **capped at 10** (`400 "Value must have 10 items or fewer."`) and clauses are ANDed (no OR). Instead: `create_saved_search` (by `serialNumber IN [...]`, or by an existing device **tag** for a stable population — `{scope:TAGS, field:tag, operator:IN, values:["<tag>"]}`), create/clear the policy to `server_groups:[]` + `device_filters_enabled:false` (targets nothing on its own), then `assign_policies_to_saved_search(uuid,[policy_id])`.
- Do **not** create a new server group to scope — group membership is exclusive, so moving devices strips their existing patch policies.

## 5. Verify and push

- **Saved-search targeting is invisible to read APIs:** `list_devices_for_policies` and `policy_detail` show `0`/`server_groups:null` even after a successful assign. You cannot confirm scheduled targeting through them — confirm on the first scheduled run or via `policy_run_results`. See the automox-api-traps memory §4.
- **For immediate certainty, push per device:** `execute_policy_now(policy_id, action:"remediateServer", device_id:<id>)`. Get integer ids via `run_saved_search(fields:["id","name","serialNumber"])`. `action` must be `remediateAll` or `remediateServer`.
- **`remediateServer` runs the remediation directly and SKIPS the evaluation** (verified 2026-07-27 on policy 502220: re-pushing to an already-remediated device re-ran remediation and returned `success` again, instead of the evaluation's already-done branch). So an on-demand push proves the remediation works and is idempotent, but proves **nothing** about the evaluation's exit codes or self-gating. To exercise the evaluation, let the policy run on its **schedule** — keep `device_filters` narrow and watch for `remediation_not_applicable` on devices that should self-gate. Budget a scheduled cycle for this before any fleet rollout.
- **Never `remediateAll`** on a policy whose targeting you can't confirm (e.g. `server_groups:null`) — a misresolve risks a broad run. Prefer explicit per-device `remediateServer`.
- Confirm outcomes with `policy_run_results` (per-device exit code + output).

## Read-only troubleshooting

- Verified 2026-07-27: if `policy_catalog` or `list_server_groups` unexpectedly returns an empty dataset despite known tenant data, resolve a policy by name with `policy_execution_counts` and map group IDs through `resource://servergroups/list`. For aggregate run evidence, use `policy_execution_timeline`; `policy_run_results` status filtering is client-side per page, so do not treat an empty filtered page as proof that no matching outcome exists.

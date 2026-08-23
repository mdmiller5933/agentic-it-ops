---
name: review-intune-byod-app-protection
description: Review or build Contoso Intune BYOD policy for personal iOS/Android phones - both MAM app protection and MDM enrollment of devices not in ABM. Use when the user asks about "BYOD policies", "app protection policies", "MAM", "make mobile experience suck less", a specific user affected by Intune mobile app protection, or asks to create a "BYOD enrollment profile", "MDM enrollment profile", or a BYOD compliance policy requiring a "pin code", "biometrics", or "no jailbreak". Reads are free; creating or assigning policy is a production write needing explicit approval.
---

# Review Intune BYOD App Protection

Use this for Contoso iOS/Android BYOD, MAM, Intune app protection policy, and related Conditional Access UX reviews. Keep the review read-only by default; Intune and Entra policy edits require explicit approval.

## Fast Path

Work from `C:\automox-mcp-main` when available.

1. Verify Graph auth with the acquire-graph-token skill (`graph-app-token.cmd` for reads).
   If a helper still needs delegated `z_admin`, run `graph-token.cmd`; on `NEED_BOOTSTRAP`
   run `Invoke-DelegatedGraphTapRemint.ps1`. Do not retry embedded `Connect-MgGraph` and do
   not ask the user to run `intune-auth-desktop.cmd`.

2. Run the BYOD inventory helper explicitly through PowerShell 7. Do not invoke the `.ps1` path directly, because Windows may open it in Notepad through file association.

   ```cmd
   C:\Progra~1\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\automox-mcp-main\scripts\review-byod-app-protection-config.ps1 -AllowInteractiveLogin -OutputPath C:\automox-mcp-main\reports\byod-app-protection-review.json
   ```

3. If Conditional Access policy review is needed, the signed-in account must have `Policy.Read.All`. Run:

   ```cmd
   C:\Progra~1\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\automox-mcp-main\scripts\review-byod-app-protection-config.ps1 -AllowInteractiveLogin -RequestConditionalAccessScope -OutputPath C:\automox-mcp-main\reports\byod-app-protection-review-with-ca.json
   ```

   If Graph returns `Forbidden`, report CA as not reviewed instead of inferring CA behavior from Intune data.

## What To Inspect

- Which APP policies are assigned, especially policies named `TEST` versus `PROD`.
- Which user or group receives the policy; for a named user, resolve their UPN and group membership before recommending changes.
- `organizationalCredentialsRequired`, `pinRequired`, biometric settings, app PIN length, and whether app PIN is disabled when a device PIN exists.
- `deviceComplianceRequired`, especially for BYOD/MAM-without-enrollment scenarios.
- Managed browser and Edge configuration for work links from Outlook, Teams, OneDrive, SharePoint, and Office.
- Data movement settings: inbound/outbound transfer, clipboard, Save As, allowed storage, backup, printing, contact sync, and screen capture.
- Offline access and wipe timers.
- Conditional Access grant controls, platform filters, app scope, include/exclude users or groups, and whether `Require app protection policy` is enforcing unsupported apps.

## Clone Or Pilot Creation

Creating, updating, assigning, or deleting Intune APP policies is a production write and requires explicit user approval. For the Teal iOS pilot pattern, use `C:\automox-mcp-main\scripts\new-intune-ios-mam-ux-pilot.ps1`; it creates or repairs an unassigned clone from `TEST_iOS_MAM`, keeps the same selected apps and data controls, and sets `pinRequired=false` plus `organizationalCredentialsRequired=false`.

When copying selected apps onto a managed app protection policy, do not POST individual apps to `/deviceAppManagement/iosManagedAppProtections/{id}/apps`; this tenant returns "No method match route template" for that path. Use the bulk action `POST /deviceAppManagement/managedAppPolicies/{managedAppPolicyId}/targetApps` with the managed mobile app collection and `appGroupType`.

## MDM Lane: BYOD Enrollment Profile + Compliance Policy (non-ABM devices)

Which artifact holds which control — get this right before building, because the three settings users
name most often do not live in one place:

| Ask | Lives in |
| --- | --- |
| Passcode required, min length, block simple, jailbreak block, OS floor | iOS **compliance policy** (`iosCompliancePolicy`) |
| Face ID / Touch ID as an access gate | **App protection (MAM)** only — there is NO biometric setting in iOS compliance policy or in any enrollment profile |
| Which enrollment flow a personal device gets | **Enrollment type profile** (`appleUserInitiatedEnrollmentProfiles`) — holds no security settings at all |

Enrollment-type choice for Contoso BYOD (`defaultEnrollmentType`), in preference order:

- `device` — Device enrollment via Company Portal. **Default pick.** Works with a personal Apple ID, no
  extra tenant prerequisites. Manages the whole device.
- `webDeviceEnrollment` — same reach, browser instead of the Company Portal app; also needs no Managed Apple ID.
- `accountDrivenUserEnrollment` — lightest touch and Apple's modern path, but gated on Managed Apple IDs,
  ABM federated auth, JIT registration, the Authenticator SSO plugin, AND a `.well-known/com.apple.remotemanagement`
  JSON file served as `application/json` from the sign-in domain. As of 2026-07-28 `contoso.com` returns
  **403** for that path, so this is a project, not a checkbox. Verify with `curl -I` before offering it.
- `user` — **deprecated**; Microsoft does not support it for new enrollments. Never pick it.

Tenant gate to check first: the default platform restriction
(`deviceEnrollmentConfigurations/{id}_DefaultPlatformRestrictions`) has
`iosRestriction.personalDeviceEnrollmentBlocked = true`. While that holds, a BYOD enrollment profile
enrolls nobody. Flipping the default opens personal iOS for every user — prefer a higher-priority
targeted `platformRestrictions` config scoped to the pilot group, and get approval either way.

Graph gotchas, both verified 2026-07-28:

- `scheduledActionsForRule` is **required in the POST body** when creating any per-platform compliance
  policy; omit it and the create fails. `ruleName` must be the literal `PasswordRequired`.
- Reading it back at `GET .../deviceCompliancePolicies/{id}/scheduledActionsForRule` returns
  **400 "No method match route template"** on this tenant (same class as the `targetApps` quirk above), on
  both v1.0 and beta. To verify the noncompliance action actually stored, expand from the parent instead:
  `GET /v1.0/deviceManagement/deviceCompliancePolicies/{id}?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)`
- Compliance policies and Apple enrollment-type profiles are **not** MAA-gated in this tenant — creates
  return a clean `201`, unlike app writes.
- Do not set `deviceThreatProtectionEnabled` — no MTD connector is wired, so it fails every device.
  Keep `managedEmailProfileRequired = false` on BYOD or devices flunk on a missing Intune email profile.
- **Red herring:** `INTUNE_A = PendingInput` on a user's `SPE_E3` licenseDetails is NORMAL in this tenant —
  verified 2026-07-28 on Avery plus three users with live enrolled iPhones, all identical. Never chase it
  or re-assign licenses over it. To judge whether an account is licensed enough to enroll, diff it against a
  user who already owns an enrolled device rather than looking for `Success`. Same for
  `INTUNE_O365 = PendingActivation` and `deviceManagement.subscriptionState = pending`.

**Adding a group to an EXISTING assignment — route matrix.** The `/assign` action REPLACES the whole
assignment list, so on a shared production object it silently drops every group you forgot to re-send.
Prefer the additive `POST .../{id}/assignments` where it exists. Verified on this tenant 2026-07-28:

| Object | Additive `POST /assignments` | Notes |
| --- | --- | --- |
| `deviceConfigurations` | ✅ 201 | use this; safe on shared profiles |
| `appleUserInitiatedEnrollmentProfiles` | ✅ 201 | |
| `mobileApps` | ✅ route works, but **MAA-gated** | see below |
| `deviceCompliancePolicies` | ❌ 400 "No method match route template" | must use `/assign`; read existing first and re-send them |

When you must use `/assign`, read `/assignments` first, rebuild the full list, append, POST, then re-read and
diff to prove nothing was lost. Watch for assignments pointing at **deleted** groups — this tenant has an
orphan (`cac213a6-c6e0-0cc4-876c-f63c33fe3699`) still referenced by ~60 app assignments and several iOS
profiles; re-sending a dead groupId through `/assign` can fail the whole call.

**App assignment writes ARE MAA-gated here** (app *creates* sometimes slip through; assignments do not).
Pre-supply the base64 `x-msft-approval-justification` header on the first POST, expect `412` plus an
`x-msft-approval-code`, and report the code — that is success-filed, not failure. Existing assignments are
untouched while the request is pending.

**iPad-only enrollment IS enforceable.** Assignment filters are supported on iOS *enrollment platform
restrictions*, and `Model` is one of the available properties (Manufacturer / Model / OS version / Ownership /
Enrollment policy name; filters do NOT work with Android enrollment restrictions). Use rule
`(device.model -startsWith "iPad")` with `deviceAndAppManagementAssignmentFilterType: include` on the
restriction's assignment target. `-startsWith` is deliberate: it matches both the marketing names Intune
enriches post-enrollment (`iPad`, `iPad (A16)`, `iPad Air 13-inch (M4)`) and raw hardware identifiers
(`iPad13,4`), while every iPhone form (`iPhone 17 Pro`, `iPhone15,2`) misses and falls through to the
default block. Filter platform value is `iOS`.

To open personal iOS for a pilot group without touching the tenant default, create a per-platform config —
`@odata.type` `#microsoft.graph.deviceEnrollmentPlatformRestrictionConfiguration`,
`deviceEnrollmentConfigurationType: singlePlatformRestriction`, `platformType: ios`, and
`platformRestriction.personalDeviceEnrollmentBlocked = false`. Prefer this over the legacy combined
`deviceEnrollmentPlatformRestrictionsConfiguration`: it scopes to iOS alone and leaves Windows/Android/macOS
on the default instead of silently carrying restrictions for them. Assign with
`POST /deviceManagement/deviceEnrollmentConfigurations/{id}/assign` and an
`enrollmentConfigurationAssignments` array. Non-default configs are priority 1..N (lower wins); the default
sits outside that race as the fallback, so a new config at priority 1 does NOT need the default changed.
Always re-read the default afterward to prove it still blocks personal enrollment.

## Answer Shape

Lead with the concrete tenant facts, then give the smallest set of changes likely to improve UX without weakening the core BYOD control. If data access is missing, name the exact missing scope or auth blocker.

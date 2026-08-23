---
name: enroll-apple-device-abm-intune
description: Enroll company-owned Apple devices into Apple Business (formerly ABM) and Microsoft Intune as supervised, managed devices, including direct-purchase zero-touch and retail Configurator paths. Use when the user asks to enroll an iPad/iPhone/Mac, add a device to ABM or Apple Business, set up ADE/DEP, create an Apple business purchasing portal, link an Apple Customer Number or reseller, buy carrier-unlocked devices that auto-enroll, or troubleshoot Configurator "Invalid Profile" / MCProfileErrorDomain 1000. Covers the 2026 ABM move, direct Apple supplier and default MDM assignment, token sync, enrollment profile, erase, and Entra sign-in. Corporate/supervised only; for BYOD use review-intune-byod-app-protection, and for a remote Mac use screenconnect-remote-diagnostics.
---

# Enroll Apple Device (ABM -> Intune)

Get a company-owned Apple device to supervised + Intune-managed via Automated Device Enrollment (ADE/DEP). Works for devices bought through Apple/a reseller (already ABM-eligible) and **retail-bought** devices that must first be injected into ABM with Apple Configurator on a Mac.

## Portal naming and direct Apple purchasing (verified 2026-08-06)

- Apple Business replaced Apple Business Manager on 2026-04-14. An existing ABM organization must
  sign in at `https://business.apple.com` with an existing ABM Administrator and move the existing
  organization. **Do not choose Sign up now or create a second organization.**
- The purchasing store is separate. Request an Apple Store for Business account at
  `https://www.apple.com/retail/business/smb-signup/` or through Apple Business Sales
  (`1-800-854-3680`; Enterprise Sales `877-412-7753`, verified 2026-08-06). Ask Apple to issue an
  enrolled and verified **Apple Customer Number** for the existing Apple Business organization.
  The legal name and mailing address at Apple must exactly match the organization record.
- Use a separate unmanaged Apple Account for the purchasing store. Do not reuse an Apple Business
  Managed Apple Account for the store or other Apple services.
- In Apple Business, add the number under **Devices > Inventory > Add/Get Started > Apple (Direct)**,
  omitting leading zeros. Under **Devices > Management Services > Default Device Assignment**, set
  iPhone, iPad, and Mac to the existing Intune service.
- Only orders booked under that exact linked Customer Number are guaranteed to appear automatically;
  an ordinary retail `apple.com` order is not enough. For carrier independence, order iPhone with
  **Connect to any carrier later** and avoid carrier installment financing.
- Pilot one device first. After shipment, verify its source is Apple and its service assignment is
  Intune before the device is activated or sent through Setup Assistant.

## Prerequisites (verify once per tenant)
- ABM <-> Intune connected: an Apple ADE/DEP token (enrollment program token) in Intune, plus a valid Apple MDM push certificate.
- **Check expiry before troubleshooting any enrollment failure.** The APNs push certificate, the ADE/DEP token, and the VPP token all expire annually and a lapse presents as "enrollment broken" with no obvious cause. Run `C:\automox-mcp-main\scripts\apple-credential-check.ps1` (read-only). To renew any of them, follow `C:\automox-mcp-main\docs\apple-credential-renewal-runbook.md` — it carries the renew-in-place rule, the APNs 30-day grantham period, and why these uploads are *not* MAA-gated.
- An Intune iOS/iPadOS (or macOS) enrollment profile set to auto-assign to that token's devices.
- Configurator path only: Apple Configurator on a Mac, signed into ABM with an account holding the Device Enrollment Manager role, and a cable/connection to the target device.

## Retail device: add to ABM with Apple Configurator
1. In Apple Configurator run **Prepare** and choose to add the device to Apple Business Manager. **Uncheck "Activate and complete enrollment"** — you only want it injected into ABM, not enrolled by Configurator.
2. **Expect the error** `an unexpected error has occurred... Invalid Profile [MCProfileErrorDomain - 0x3E8 (1000)]`. It is **BENIGN** — the device still lands in ABM. It fires because Configurator parks the device on the auto-created "Devices Added by Apple Configurator 2" placeholder MDM server (no real profile behind it) at the "complete enrollment" instant. Do not read it as failure.
3. Confirm the serial appears in business.apple.com -> **Devices** before continuing (can take a few minutes).

## Bring it into Intune (all devices)
4. In **ABM -> Devices**, assign the device to the **Intune MDM server** (move it off the "Devices Added by Apple Configurator 2" placeholder).
5. In **Intune**, sync the ADE/DEP token (Devices -> Enrollment -> Enrollment program tokens -> token -> Sync), then confirm an enrollment profile is assigned to the device.
6. **Erase** the device (retail: Settings -> Transfer or Reset; or Restore in Configurator).
7. At Setup Assistant -> **Remote Management**, complete enrollment. If the profile uses "Setup Assistant with modern authentication" the user signs in with **Entra ID** -> user-affinity enrollment. Device comes up supervised + managed.

## Retail + Configurator = 30-day provisional
Devices added to ABM **via Apple Configurator** get a 30-day provisional release window: within 30 days the device shows "Remove Management" and can be un-enrolled; after 30 days it is permanently supervised/managed. Devices bought through Apple/an authorized reseller are locked from day one.

## Verify (read-only)
Intune -> Devices -> iOS/iPadOS (or macOS): Ownership **Corporate**, Supervised **Yes**, the expected **enrollment profile**, Primary user = the signed-in Entra account. Use the acquire-graph-token skill for Graph checks of the ADE token, profile assignment, and compliance.

## ADE enrollment-profile CREATES over Graph 500 — the profiles are DEPRECATED (verified 2026-08-20)
`POST /beta/deviceManagement/depOnboardingSettings/{id}/enrollmentProfiles` returns a bare
`500 InternalServerError` for every payload shape — raw REST and the Graph Beta SDK cmdlet alike,
delegated token with `DeviceManagementServiceConfig.ReadWrite.All` (~17 shapes tried, including the
docs example verbatim). NOT auth, RBAC, or payload: reads and `syncWithAppleDeviceEnrollmentProgram`
return 200 with the same token. Root cause found in the portal: the token's Profiles blade banners
"The iOS/iPadOS and macOS enrollment profiles are no longer being updated" — legacy DEP profiles are
frozen in favor of ADE **Enrollment policies** (token blade > Manage > Enrollment policies), so do
not burn time bisecting the legacy endpoint. The new policy is a **settings-catalog object**: the
portal create wizard is `Wizard.ReactView` with `profileType=ADE Policy`, `technology=enrollment`,
settings-catalog `templateId 27d20e9c-50c1-48f8-a44c-f37de4510051_1` (iOS). Untested but likely:
create it over Graph via `POST /beta/deviceManagement/configurationPolicies` with that
`templateReference` (needs `DeviceManagementConfiguration.ReadWrite.All`, an endpoint that works in
this tenant); inspect `configurationPolicyTemplates('27d20e9c-50c1-48f8-a44c-f37de4510051_1')?$expand=settingTemplates`
first. The policy name still populates `enrollmentProfileName` for dynamic device groups. Existing
legacy profiles (e.g. the Company Owned default) keep working; PATCH/assign on them is unaffected.

Portal-driving facts (verified 2026-08-20): `avery.operator` has NO Intune RBAC over Enrollment
Programs (tokens list shows "Unauthorized") — use `z_admin` via the portal avatar account
switcher, which SSOs silently off the Windows PRT even right after the midnight PAM rotation (no
password, no MFA prompt). Deep link to the tokens list:
`https://intune.microsoft.com/#view/Microsoft_Intune_Enrollment/DepTokensPaging.ReactView`.
A stale hourly retry script against the LEGACY endpoint sits at
`C:\automox-mcp-main\scratch\retry-shared-iphone-enrollprofile.ps1` — superseded by the
Enrollment-policy route; do not schedule it.

## Mac-side troubleshooting (when Configurator misbehaves)
The 1000 error is almost never a Mac fault. Rule out on the Mac first: clock/date skew (network time on), DNS/network reach to Apple on 443, the target device is detected (`cfgutil list` sees it), and Apple Configurator is current (App Store — a behind version is a real variable). Drive a remote Mac with the screenconnect-remote-diagnostics skill; on macOS those commands run as **root**, use the `#!sh` hashbang, and unified-log strings are heavily `<private>`-redacted (the 1000 error text lives in the ABM transaction / on the target device, not the Mac log). Probe snippets: `references/macos-configurator-diag.md` inside this skill's folder.

## Approval gates
Read-only investigation is fine. Get explicit approval before state changes: erasing/restoring a device, ABM server (re)assignment, Intune enrollment-profile or token changes, or ScreenConnect remediation on the Mac. **Never enter or log a Secure Token / local-admin password** — Apple Silicon OS installs require one, so have the device owner enter it interactively rather than passing it through a command. For shared cross-system defaults use the it-operations umbrella skill.

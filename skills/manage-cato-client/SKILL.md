---
name: manage-cato-client
description: Package, configure, diagnose, and fleet-remediate the Cato Networks Windows client for Contoso. Use when the user mentions Cato, the Cato intunewin/package, "Cato won't connect", seamless auth, connect on boot, "connect at startup", the contoso-energy subdomain, Cato not signing in automatically after login or reboot, or pushing the Cato registry fix to devices. Covers the version-tolerant Intune Win32 package, the 64-bit HKLM\SOFTWARE\CatoNetworksVPN bootstrap keys (SubdomainForSeamlessAuth, ConnectOnBoot, LaunchAuthPageOnStartup, SeamlessAuthAllowUI; remove InitialAlwaysOn), endpoint registry/log diagnostics, and fleet remediation. For general Win32 packaging use package-intune-win32-app; for the Automox fleet worklet use deploy-automox-worklet; for remote endpoint access use screenconnect-remote-diagnostics.
---

# Manage Cato Client (Contoso)

Cato Networks SDP client for Windows, deployed via Intune Win32, using Windows-credentials seamless authentication. Treat endpoint, Intune, ScreenConnect, and Automox writes as production — get explicit approval before changing state or rebooting.

## The core config (get this right first)

Cato reads its bootstrap config from the **native 64-bit** view of `HKLM\SOFTWARE\CatoNetworksVPN`:

- `SubdomainForSeamlessAuth = contoso-energy` (String) — Contoso's Cato account subdomain (CMA > Access > Single Sign-On)
- `LaunchAuthPageOnStartup = 1` (DWord)
- `ConnectOnBoot = 1` (DWord)
- `SeamlessAuthAllowUI = 1` (DWord)
- **Remove `InitialAlwaysOn`** — unsupported with Windows-credentials seamless auth.

**64-bit hive is mandatory.** Intune runs the install wrapper in a 32-bit process, which redirects `HKLM:\SOFTWARE` writes to `WOW6432Node`, where Cato never looks — seamless auth then silently fails. Always write with `[Microsoft.Win32.RegistryView]::Registry64` (or `reg ... /reg:64`). See the intune-win32-registry-wow6432-redirection memory. Symptom: keys present under `WOW6432Node\CatoNetworksVPN` but absent under `SOFTWARE\CatoNetworksVPN`.

## Packaging (Intune Win32)

Use the package-intune-win32-app skill for mechanics. Cato specifics:

- Package folder: newest version folder under the Cato app folder in the Intune Apps root (known-good 2026-07: `6.4.6.8830`).
- Baseline installer, **version-tolerant detection** (installed version >= baseline) so Cato/Automox/winget self-updates don't force reinstalls; keep the bootstrap registry OUT of detection.
- Install wrapper writes the four keys via `Registry64` and removes `InitialAlwaysOn`.
- Intune: install as System, `3010` = soft reboot, pilot-first.
- Tenant has two Win32 Cato apps — the pilot `(TEST) Cato VPN` (this package) and an older `Cato VPN` (setup `CatoClient.exe`). Confirm which one an assignment targets.

## Endpoint diagnostics ("why didn't it connect / sign in?")

1. Read **both** registry views (32-bit vs 64-bit). Keys only in `WOW6432Node` = the redirection bug above.
2. Client logs: `C:\Program Files (x86)\Cato Networks\Cato Client\cato_vpn_*.log` and `cato_ua_*.log`. **Timestamps are UTC** (convert from local).
3. `loadPreLoginSettings ... Account workspace (Subdomain)=` **empty is EXPECTED** — pre-login (connect before any user logs in) is intentionally disabled here; it is NOT the seamless-auth signal.
4. Successful post-reboot seamless auth = a **new** client process PID plus a `/ua` API response carrying `login_name` after the boot time. Services `CatoNetworksVPNService` and `CatoNetworksDEMService` should be Running.

## Remediating already-installed devices

Devices that installed the old (WOW6432Node) package won't reinstall — version-tolerant detection already sees Cato present, so Intune reports compliant. Re-uploading the fixed package only helps net-new installs. To fix existing devices, push the four keys to the 64-bit hive, then have the user reboot on their own time:

- **One machine:** use the screenconnect-remote-diagnostics skill; run as SYSTEM, write via `Registry64`, no reboot.
- **A fleet / group:** use the deploy-automox-worklet skill (evaluation self-gates on Cato-installed + keys-wrong; remediation writes the keys; no reboot).

The registry write is dormant until Cato next starts; a reboot is the reliable trigger. Never force a reboot without approval — it drops the user's active VPN session.

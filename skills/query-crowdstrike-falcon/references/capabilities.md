# Falcon API capabilities (verified 2026-08-19)

Cloud ID `de236130afce4265a75c8ed28e2d373a`, cloud `us-2`,
`https://api.us-2.crowdstrike.com`. OAuth2 `POST /oauth2/token` returns HTTP 201,
`expires_in=1799`, and **does not** include a `scope` list — probe endpoints instead.

## Allowed (HTTP 200 on this client)

| Area | Endpoints | Notes |
| --- | --- | --- |
| Hosts | `GET /devices/queries/devices/v1`, `/devices/combined/devices/v1`, `/devices/queries/devices-scroll/v1`, `/devices/entities/devices/v2` | Fleet size 425 that day |
| Hidden hosts | `GET /devices/queries/devices-hidden/v1` | 0 hidden |
| Host groups | `GET /devices/queries/host-groups/v1`, `/devices/combined/host-groups/v1` | 6 groups |
| Alerts | `GET /alerts/queries/alerts/v1` and `v2`; `POST /alerts/combined/alerts/v1`; `POST /alerts/entities/alerts/v2` | GET combined is 405 |
| Spotlight | `GET /spotlight/queries/vulnerabilities/v1`, `/spotlight/combined/vulnerabilities/v1` | `filter` is required; facets `cve`, `host_info`, `remediation`, `evaluation_logic` |
| Prevention policy | `GET /policy/queries/prevention/v1`, `/policy/combined/prevention/v1` | 15 policies (phased + platform_default + OT) |
| Sensor-update policy | `GET /policy/queries/sensor-update/v1`, `/policy/combined/sensor-update/v1` | 3 platform_default policies |
| Custom IOCs | `GET /iocs/queries/indicators/v1`, `/iocs/combined/indicator/v1` | 0 indicators |

The Detects API is decommissioned; use Alerts. Incidents paths 404 here.

## Denied (403 scope not permitted)

Discover (hosts/apps/accounts/logins), Intel, users, RTR, quarantine, ZTA, firewall
rule-groups, installation tokens, sensor installers, event streams, FalconX reports,
scheduled reports, message center, ODS, FileVantage, IOA rule groups, Kubernetes,
data-protection, content-update/ml/sv/ioa exclusions, response policy, firewall
policy, device-control **policy** collection (hosts still show an applied device-control
policy id).

Write probes with empty payloads (no mutation): contain, lift_containment, hide_host,
unhide_host, create IOC, PATCH alert status, create prevention policy, RTR session
start — all 403.

## Host groups (that day)

| Name | Type | Rule |
| --- | --- | --- |
| Contoso Win Workstation Group | dynamic | Windows 10/11 |
| Contoso Win Server Group | dynamic | Windows Server 2025 |
| Contoso Linux Group | dynamic | Ubuntu 24.04 |
| IT Investigate | static | hostname allow-list (legacy AP-/CONTOSO- names plus some WKS) |
| OT Systems | static | `NorthFieldOTLAPTOP1`–`7` (6 names) |
| Termination - Auto_Contain | static | empty |

Windows workstations were on prevention **Phase 2 - interim protection**. Sensor-update
was `platform_default` (Windows build `21108\|n-1`). Uninstall protection was ENABLED
on sampled hosts. Hosts still carry applied firewall, device-control, remote-response,
and other policy ids even though those **policy APIs** are 403.

## Fleet snapshot that day

- 425 hosts: 424 Windows, 1 Linux (`Linux001` / serial `SN0005`), 0 Mac
- 412 workstations, 13 servers
- 423 normal, **1 contained** (`WKS-5012` / `PF5A8R8B`, last seen 2026-08-13)
- 2 RFM (`reduced_functionality_mode:'yes'`): `WKS-SN0033` (sensor 7.31), `WKS-SN0117` (last seen 2026-07-15)
- Alerts ~1682 total; ~1531 `status:'new'` (mostly automated-lead signals); 191 `type:'ldt'`; 219 `severity:>=50`
- Spotlight open: Critical 3622, High 52544, Medium 24279, Low 1034

Treat those counts as a known-good example, not a cache. Re-run `summary` for current numbers.

---
name: query-crowdstrike-falcon
description: Query Contoso CrowdStrike Falcon for hosts, alerts, Spotlight vulnerabilities, host groups, and prevention/sensor-update policies via the US-2 REST API. Use when the user asks about Falcon, CrowdStrike, "is this device in CrowdStrike", sensor version, containment, RFM, detections, alerts, Spotlight CVEs, or Falcon host groups. This API client is read-only (no contain, RTR, Intel, Discover, or policy writes). Vulnerability KPI scoring stays in analyze-vulnerability-kpis; Rapid7 remains the leadership workbook source.
---

# Query CrowdStrike Falcon

Read-only Falcon API for Contoso (`https://api.us-2.crowdstrike.com`). Credentials live in
`C:\temp\temp\env.local` (`Client ID` / `Secret` / `Base URL`) or `FALCON_CLIENT_ID` +
`FALCON_CLIENT_SECRET` + optional `FALCON_BASE_URL`. Never print the secret or bearer token.
Prefer moving this record into Keeper later via the retrieve-keeper-secret skill; do not copy
the env file into the skill folder.

Verified 2026-08-19: OAuth succeeds; this client can **read** Hosts, Alerts, Spotlight,
prevention/sensor-update policies, host groups, and custom IOCs. Contain, hide, tag, alert
status updates, RTR, Intel, Discover, users, firewall policy, and sensor installer download
all return `403 scope not permitted`. Do not attempt those writes.

## Workflow

1. Look the device up by **serial first**, then exact hostname. After the WKS rename,
   Falcon hostnames are usually `WKS-<serial>`. Prefix wildcards work (`hostname:'WKS-*'`);
   mid-string `*SERIAL*` does not.
2. Run the bundled helper with any Python 3 (`py -3`):

```text
scripts/falcon-query.py
```

```powershell
py -3 "<this skill's folder>\scripts\falcon-query.py" auth
py -3 "<this skill's folder>\scripts\falcon-query.py" host SN0046
py -3 "<this skill's folder>\scripts\falcon-query.py" summary
py -3 "<this skill's folder>\scripts\falcon-query.py" alerts --hostname WKS-SN0042 --limit 20
py -3 "<this skill's folder>\scripts\falcon-query.py" alerts --filter "type:'ldt'+status:'new'" --limit 20
py -3 "<this skill's folder>\scripts\falcon-query.py" spotlight --hostname WKS-SN0026 --limit 20
```

3. Summarize sensor health: `status` (normal/contained), `reduced_functionality_mode`,
   `agent_version`, last seen, applied prevention policy name, group names.
4. For detections, **do not** treat `status:'new'` as EPP detections. Most of those rows are
   `product:automated-lead-context` / `type:signal` with null severity. Use `type:'ldt'` or
   `severity:>=50`, and filter hosts with `device.hostname:'...'` (plain `hostname:` returns 0).
5. Spotlight is instance-heavy (~80k open). Always keep a severity+status filter and a limit.
   Join to other systems by serial (from the Hosts API) or hostname; Spotlight `host_info`
   has hostname, not serial. KPI scoring still belongs in analyze-vulnerability-kpis / Rapid7.

## Guardrails

- Read-only. If the user asks to contain, lift containment, hide a host, change a policy,
  run RTR, or close an alert, say this client cannot do it and stop.
- Endpoint shell work stays in the screenconnect-remote-diagnostics skill. Intune
  `FalconSensor` package work stays on the Graph/Intune path.
- Details: `references/capabilities.md` and `references/fql.md` inside this skill's folder.

---
name: check-autopilot-serials
description: Check one or more device serial numbers against Microsoft Intune Windows Autopilot identities and Intune managed devices. Use when the user sends serial numbers and asks whether devices are enrolled, registered, imported, present in Autopilot, or already managed in Intune, especially for Contoso Windows laptop intake or provisioning checks.
---

# Check Autopilot Serials

## Workflow

Use live Microsoft Graph data. This is a read-only workflow.

1. Extract serial numbers from the user message. Normalize case and remove punctuation such as commas or semicolons.
2. If working in the Contoso workspace, mint a Graph token with the acquire-graph-token skill
   (`graph-app-token.cmd` is enough for this read-only Autopilot/Intune lookup). Do not ask
   for device-code or `intune-auth-desktop.cmd`.
3. Run the bundled script, `scripts/check-autopilot-serials.ps1` inside this skill's folder
   (same content under `~/.claude/skills` and `~/.codex/skills`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<this skill's folder>\scripts\check-autopilot-serials.ps1" SD004LB7 SD004LB0 -OutputDir "C:\automox-mcp-main\reports"
```

4. Summarize per serial:
   - `autopilotEnrolled: true` means a Windows Autopilot device identity matched the serial.
   - `enrollmentState` is the Autopilot identity state, commonly `enrolled`.
   - Include manufacturer, model, group tag, deployment profile assignment status, and Autopilot identity ID when present.
   - Include Intune managed-device name, user, compliance state, managed device ID, and last sync when present.
   - If both Autopilot and managed-device checks miss, say the serial was not found in Autopilot or Intune by that serial.

## Important Details

- Do not import, delete, assign, wipe, sync, or otherwise change devices unless the user explicitly asks and approves the production-impacting action.
- The Graph Autopilot identities endpoint may reject direct `$filter=serialNumber eq '...'` queries. The bundled script deliberately pages Autopilot identities and filters locally, then uses managed-device serial filtering for the Intune cross-check.
- If the user asks for a broad inventory or history rather than a live serial check, use the endpoint cache workflow from `C:\automox-mcp-main\docs\endpoint-cache-runbook.md` when available.
- Do not print access tokens or authentication material.

## Script

Bundled script:

```text
scripts/check-autopilot-serials.ps1
```

The script prints a compact JSON summary to stdout and writes a timestamped JSON report. Pass
`-OutputDir` with an explicit base directory (normally `C:\automox-mcp-main\reports` in the Contoso
workspace); without it the report lands in a `reports` folder under whatever the current working
directory happens to be.

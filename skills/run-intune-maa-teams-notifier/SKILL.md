---
name: run-intune-maa-teams-notifier
description: Run the existing Contoso Intune Multi Admin Approval (MAA) Teams notifier. Use on any scheduled/cron run that checks pending Intune MAA approval requests, and whenever the user asks to check pending Intune approvals or MAA requests, post new approval cards to the Teams group chat "Intune MAA Group", verify or summarize notifier health/status, or troubleshoot the local intune-maa-teams-notifier automation.
---

# Run Intune MAA Teams Notifier

## Fast Path

Run the local script from `C:\automox-mcp-main`:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\automox-mcp-main\scripts\notify-intune-maa-approvals-to-teams.ps1
```

If `pwsh.exe` is unavailable, use `powershell.exe` with the same arguments.

Then read:

```text
C:\automox-mcp-main\reports\intune-maa-teams-notifier-status.json
```

Report only:

- `status`
- `pendingCount`
- `sentCount`
- `sentRequestIds`, only when non-empty
- `errorCount`
- `errors`, only when non-empty

## Rules

- Do not print, echo, log, or inspect `INTUNE_MAA_TEAMS_WEBHOOK_URL`.
- Do not paste webhook URLs, Graph tokens, refresh tokens, or cookies into chat.
- Do not browse Teams, Power Automate, or Intune for routine scheduled runs.
- Do not change Intune, Graph, Teams, Power Automate, or local script state from this skill.
- Treat this workflow as already approved to send Teams notifications for newly pending Intune MAA requests.
- If no new request exists, say the notifier is healthy and sent nothing.

## Failure Handling

If the script exits nonzero, read the status JSON if it exists and summarize the failure without secrets.

Common cases:

- `status: blocked` and reason mentions `INTUNE_MAA_TEAMS_WEBHOOK_URL`: say the Teams webhook environment variable is missing.
- Graph authentication errors: say the z-account Graph context needs repair and suggest `C:\automox-mcp-main\scripts\intune-auth-test.cmd`.
- Teams webhook HTTP errors: say the Power Automate Teams webhook may need to be recreated or re-copied.

## Existing Setup

- Script: `C:\automox-mcp-main\scripts\notify-intune-maa-approvals-to-teams.ps1`
- Runbook: `C:\automox-mcp-main\docs\intune-maa-teams-notifier.md`
- State file: `C:\automox-mcp-main\reports\intune-maa-teams-notifier-state.json`
- Status file: `C:\automox-mcp-main\reports\intune-maa-teams-notifier-status.json`
- Teams chat: `Intune MAA Group`
- Approval button target: `https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/TenantAdminMenu/~/multiAdminApproval`

## Automation Guidance

This skill is intentionally low-reasoning. For a scheduled automation in either tool (Codex cron
or a Claude Code scheduled task), prefer:

- Five-minute cron cadence while MAA approvals are active.
- A cheap/mini-class model and `minimal`/`low` reasoning effort when available.
- A prompt that explicitly invokes this skill by name (`$run-intune-maa-teams-notifier` in Codex;
  "use the run-intune-maa-teams-notifier skill" in Claude Code) and asks for the compact status
  summary only.

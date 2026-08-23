---
name: ssh-access
description: Fast SSH access workflow for Contoso-managed Windows endpoints. Use when the user asks to SSH into, open a shell on, or run a command over SSH on a Contoso laptop or workstation identified by hostname, serial, or user - including checking Cato VPN reachability, ScreenConnect live session metadata, local Contoso SSH keys, or port 22/sshd readiness before opening an interactive session. Prefer this over ScreenConnect command execution when an interactive shell or quick remote command is the goal and the endpoint is reachable over Cato.
---

# Contoso SSH Access

Use the bundled fast-path script first. It queries ScreenConnect live for the target endpoint, extracts current private/public candidate addresses, tests TCP 22 and SSH banner readiness, then optionally launches `ssh`.

## Fast Path

The fast-path script is `scripts/contoso-ssh-fast-path.mjs` inside this skill's folder (same
content under `~/.claude/skills` and `~/.codex/skills`); substitute that full path in the
commands below. It works from any working directory:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08
```

To connect after the checks:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08 --connect
```

When the endpoint uses the Contoso local admin key pattern, connect as `ContosoAdmin`:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08 --screenconnect-check --connect --user ContosoAdmin
```

If live metadata is stale or the user just connected to Cato, include a read-only endpoint network check:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08 --screenconnect-check
```

If SSH reaches the endpoint but key authentication fails, include a read-only auth check:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08 --auth-check
```

To run a remote command instead of an interactive shell:

```powershell
node "<this skill's folder>\scripts\contoso-ssh-fast-path.mjs" LAPTOP-UNNAMED08 --connect -- hostname
```

## Defaults

- Use live ScreenConnect `GetSessionsByFilter` when available. It is the quickest source for current Cato/private IP and online state.
- Fall back to `%TEMP%\codex-endpoint-cache\endpoint-inventory-join.json` only when live ScreenConnect env is missing or unavailable.
- Use `C:\Users\AveryOperatorContrac\.ssh\id_ed25519_contoso_ssh` automatically when it exists.
- Use `--screenconnect-check` when the ScreenConnect session is online but the advertised private IP is not reachable; it runs only read-only checks for IP configuration, `sshd`, listeners, and OpenSSH firewall rules.
- Use `--auth-check` when SSH reaches the endpoint but returns `Permission denied`; it checks `sshd_config`, administrator/user `authorized_keys` file presence, and whether the local `.pub` key is already present.
- If `sshd_config` routes the `administrators` group to `C:\ProgramData\ssh\administrators_authorized_keys` and that file contains the local Contoso public key, try `--user ContosoAdmin` before trying AzureAD user formats.
- Keep ScreenConnect auth material and SSH private key contents out of chat, logs, and generated files.
- Treat ScreenConnect endpoint commands, firewall changes, service restarts, installs, reboots, and policy changes as production-impacting. Ask for explicit approval before changing state.

## If SSH Fails

Use the script output to distinguish cases:

- `tcpOpen=false`: network path is blocked or the address is stale. Confirm the user is on Cato, then rerun the script.
- `tcpOpen=true` but `sshBanner=false`: something is accepting TCP but not completing SSH. Try the next candidate address or inspect the endpoint with ScreenConnect.
- No live ScreenConnect match: use the it-operations skill and endpoint cache to confirm hostname, serial, user, and current ownership.

For endpoint-local SSH health checks, use the screenconnect-remote-diagnostics skill and run read-only checks only: `sshd` service status, port 22 listeners, OpenSSH firewall rules, and `Get-NetIPConfiguration`.

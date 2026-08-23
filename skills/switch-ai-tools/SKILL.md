---
name: switch-ai-tools
description: Hand an in-progress task from one AI coding tool to another (Claude Code, Codex, Cursor) so the next session resumes instead of restarting, and pick up a handoff someone left. Use when the user says "switch to", "continue this in", "hand this off", "pick this up over there", "I'm moving to the other tool", "what was I working on", or asks why two tools disagree about skills, memory, or which MCP servers exist. Covers writing the shared handoff note, clearing it once the work lands, and the context sync that mirrors skills, global guidance, per-project memory, and MCP server definitions between tool homes.
---

# Switch AI tools without losing the thread

Everything shared between tools lives under `~/.ai-sync`, which owns one script for state
(`sync-ai-context.ps1`) and one for task handoff (`handoff.ps1`). Both are safe to re-run.

## What is already shared automatically

| Thing | Where it lives | Direction |
|---|---|---|
| Skills | `<tool home>/skills/<name>/` | both ways, newest wins |
| Global guidance | `CLAUDE.md` / `AGENTS.md` | both ways, newest wins |
| Per-project memory | `~/.claude/projects/<slug>/memory/` and `~/.codex/memory/<slug>/` | both ways |
| MCP servers | `~/.ai-sync/mcp-servers.json` -> both tools' configs | both ways |
| Auto-generated global memory | `~/.codex/memories/` -> `~/.claude/memory/codex-global/` | one way, read-only |

Not shared, by design: conversation transcripts, auth tokens, and servers a tool spawns from its
own runtime directory. A tool restart is needed before it sees new skills or MCP servers.

### Cursor is a consumer, not a third peer (added 2026-08-06)

The table above is Claude Code <-> Codex. Cursor gets a subset, one way:

| Thing | Cursor target | Direction |
|---|---|---|
| Skills | `~/.cursor/skills/<name>/` | junction to `~/.claude/skills/<name>` — edits write through |
| MCP servers | `~/.cursor/mcp.json` | **one way only** |
| Global guidance | — | not synced |
| Per-project memory | — | not synced |

Two consequences to state plainly rather than rediscover:

- **Add MCP servers in Claude Code or Codex, never in Cursor.** A server added inside Cursor is
  not read back and will be silently dropped from `mcp.json` on the next sync. Two-way needs a
  per-side manifest to tell an intentional deletion from a not-yet-synced addition, and Cursor has
  none. Skills are exempt — they are junctions, so editing one from Cursor edits the real folder.
- **Guidance and memory cannot be file-synced to Cursor.** Cursor's global equivalent of
  `CLAUDE.md` is User Rules, which lives in Cursor's internal state, not a file. So Cursor will not
  auto-run the context sync either: it consumes what the other two tools have already synced.

### Copilot Cowork is a consumer, not a fourth peer (added 2026-08-15)

Cowork loads custom skills from OneDrive `/Documents/Cowork/skills/<name>/SKILL.md` at the start
of each conversation. The sync copies real files there (not junctions — OneDrive does not upload
reparse points). Codex-only `agents/openai.yaml` is omitted.

| Thing | Cowork target | Direction |
|---|---|---|
| Skills | OneDrive `Documents/Cowork/skills/<name>/` | **one way**, real files |
| MCP / guidance / memory | — | not synced |

Edits made in Cowork do not flow back. Skills created only in Cowork (names the sync has never
projected) are left alone. A skill deleted from Claude and Codex is removed from Cowork on the
next sync, after a backup. Microsoft caps custom skills at 50, and each `SKILL.md` at 1 MB.

Also note the sync only manages **user-scope** MCP servers. Connectors supplied by a host app
(Claude Desktop / Cowork) are not in `~/.claude.json`'s `mcpServers`, so they never reach the
canonical set or Cursor — expect far fewer servers in Cursor than the host app shows.

## Handing off

Write the note **before** the user closes the tool. Do not paste a transcript — write what the
next session cannot reconstruct from the repo: what is done, what is half-done, the next concrete
step, and any dead end already ruled out.

```powershell
# Multi-line bodies: write a temp file first. -Body is fine for one-liners.
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\handoff.ps1" `
  -Write -From <claude|codex|cursor> -Title "<short task name>" -BodyFile "<path>.md"
```

Then run the context sync in the same turn, so the other tool starts from current skills and
memory as well as the note.

## Picking one up

The sync prints any active handoff at session start, so it usually arrives unasked. To check on
demand: `handoff.ps1 -Show` (exits 1 when none is active) or `-Status` for one line.

One note is active at a time; writing a new one archives the previous to `handoff/archive/`.
Reading does not consume it — both tools may start after one handoff. When the work is finished,
clear it so the next session does not re-inherit stale context:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\handoff.ps1" -Clear
```

Notes older than 24h stop being surfaced and are reported as stale instead.

## MCP servers

`~/.ai-sync/mcp-servers.json` is both the shared definition set and the manifest that makes
deletions stick. Add or edit a server in either tool and the next sync copies it across; delete it
from one and the deletion propagates. Secret-looking `env` values are deliberately not stored
there — reference a secret manager entry instead of pasting a literal, or that variable will have
to be set by hand in each tool.

If the two tools disagree and neither is a known edit, the sync refuses to guess and logs an MCP
conflict. Resolve it by naming the authority:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\sync-ai-context.ps1" -McpWinner claude
```

## When something did not cross over

Check `~/.ai-sync/sync.log` first — every copy, deletion, conflict, and error is logged with a
timestamp. Then, in order: confirm the sync actually ran this session (guidance files instruct it
at session start, and one host also runs it from a real session-start hook); confirm the item is
in the authoritative location for its type from the table above; restart the receiving tool.

Nothing is deleted without a backup under `~/.ai-sync/backups/<timestamp>/`, so a wrong sync is
recoverable — recover from there rather than reconstructing by hand. Use `-DryRun` to preview.

To add or change a shared skill, use the author-shared-skill skill; it owns the description rules
both routers depend on.

# AI context sync (Claude Code ⇄ Codex)

Two scripts keep the tools interchangeable:

- `sync-ai-context.ps1` — mirrors shared state between `~/.claude` and `~/.codex`.
- `handoff.ps1` — moves an *in-progress task* between tools.

## What is shared

| Area | Claude | Codex | Direction |
|------|--------|-------|-----------|
| Skills | `~/.claude/skills/<name>/` | `~/.codex/skills/<name>/` | both ways |
| Guidance | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` | both ways |
| Project memory | `~/.claude/projects/<slug>/memory/` | `~/.codex/memory/<slug>/` | both ways |
| MCP servers | `~/.claude.json` → `mcpServers` | `~/.codex/config.toml` → `[mcp_servers.*]` | both ways, via `mcp-servers.json` |
| Auto global memory | `~/.claude/memory/codex-global/` | `~/.codex/memories/` | Codex → Claude only |

Skills are the only shared *procedure* format: Codex removed custom prompts (`~/.codex/prompts`)
in favour of skills, so a skill is what both tools can load. Claude-only slash commands in
`~/.claude/commands/` are deliberately not synced — Codex has nothing to read them with.

Never shared: conversation transcripts, auth tokens, and servers a tool spawns from its own
runtime tree (Codex's `node_repl` is ignored by name and by runtime path).

## Behavior

- **Bidirectional, newest-wins** by last-write time (timestamps are preserved across copies so this stays truthful).
- **Deletions are honored, not resurrected.** `state.json` records what was synced last run. A file
  that was synced before, is unchanged on the surviving side, and is now gone from the other is
  treated as an intentional deletion: backed up, then removed. A genuinely new file is copied
  across; a file you *edited* is kept, never deleted.
- **Backs up** every overwritten file — and both versions of any conflict — under `backups/<timestamp>/`.
- **Conflicts** (different content, near-equal timestamps within 5s) are skipped and logged.
- Excludes Codex `.system` skills, plugin caches, `node_modules`, `__pycache__`, etc.
- Scaffolds `agents/openai.yaml` for Claude-origin skills so Codex lists them, and maintains
  per-skill junctions in `~/.agents/skills` for Codex's newer discovery path.

### MCP servers

`mcp-servers.json` is both the canonical set and the deletion manifest, so the rules match the file
sync. Two deliberate limits:

- **Secrets never land in it.** An `env` value is stored only if the key does not look secret-bearing
  (`key`, `token`, `secret`, `password`, `credential`, `auth`) or the value is a reference
  (`keeper://…`, `${…}`, `$env:…`, `%VAR%`). Anything else is stored as `__ai_sync_preserve__` and
  each tool keeps its own value; the run warns if the target has none.
- **Stand-offs are not guessed.** If both tools disagree and no manifest entry says which one
  changed — including the very first run — the sync logs an MCP conflict and changes nothing.
  Resolve with `-McpWinner claude` or `-McpWinner codex`.

`.claude.json` is edited by splicing only the `mcpServers` value span and re-parsing before writing,
so the rest of that large live file is preserved byte for byte.

## Handing a task between tools

```powershell
# leaving one tool mid-task
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\handoff.ps1" `
  -Write -From codex -Title "Cato reg fix" -BodyFile note.md

# the next session in ANY tool prints it automatically at session start
# when the work is done
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\handoff.ps1" -Clear
```

One note is active at a time (`handoff/HANDOFF.md`); writing a new one archives the previous to
`handoff/archive/`. Reading does not consume it, so both tools can start from the same note. Notes
older than 24h stop being surfaced. `-Show` prints it on demand, `-Status` gives one line.

## Run it

```powershell
# preview (writes nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\sync-ai-context.ps1" -DryRun

# real sync
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.ai-sync\sync-ai-context.ps1"
```

## Automatic run before each chat

- **Claude Code:** `SessionStart` hook in `~/.claude/settings.json`. Confirmed firing (verified 2026-08-05).
- **Codex:** instruction block at the top of `~/.codex/AGENTS.md` — best-effort, not a lifecycle hook.

Because the handoff banner is printed on stdout even under `-Quiet`, both routes deliver it into
the session.

Log: `sync.log`. Backups: `backups/`. Nothing is deleted without a backup first.

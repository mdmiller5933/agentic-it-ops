---
name: author-shared-skill
description: Create, update, or repair an agent skill shared across Claude Code, Codex, Cursor, and Copilot Cowork through the ~/.ai-sync mirror. Use when the user asks to create a skill, write a skill, add a skill for something, or fix a skill; when a task-end capture check calls for writing a procedure down; when a skill failed to auto-activate and its description needs rewriting; or when a synced skill is missing from a tool's skill list and discovery needs troubleshooting.
---

# Author Shared Skill

Every personal skill here is read by Claude Code, OpenAI Codex, Cursor, and Copilot Cowork.
The context-sync script (`~/.ai-sync/sync-ai-context.ps1`) mirrors
`~/.claude/skills/<name>/` <-> `~/.codex/skills/<name>/` (whole folders, newest-wins, backed up
before overwrite or delete), generates Codex's `agents/openai.yaml` from the SKILL.md frontmatter,
keeps write-only junctions at `~/.agents/skills/<name>` and `~/.cursor/skills/<name>` (see
Discovery troubleshooting), and copies each skill as real files into OneDrive
`Documents/Cowork/skills/<name>/` so Copilot Cowork can load it. The same script also syncs
global guidance, per-project memory, and MCP server definitions, and surfaces cross-tool task
handoffs — the switch-ai-tools skill covers those.

A skill is the ONLY procedure format both tools load: Codex removed custom prompts
(`~/.codex/prompts`) in favour of skills, and Claude-only slash commands in `~/.claude/commands/`
are not synced. So anything a second tool must be able to run belongs here, not in a command file.
Consequences:

- Write exactly ONE `SKILL.md`, in the running tool's home. Never edit both copies in one change,
  never hand-edit the generated `agents/openai.yaml` (it is presentation-only for the Codex
  app menu; only the SKILL.md `description` drives auto-activation in both tools), and never
  treat the OneDrive `Documents/Cowork/skills/` copy as a source — it is overwritten on the
  next sync. Cursor junctions write through to `~/.claude/skills`.
- A skill change is only done once the sync has re-run in the same turn as the file write
  (check `~/.ai-sync/sync.log` shows the Claude/Codex mirror and a `COWORK` copy). The other
  coding tools see the change at their next session start; Codex may need a restart. Copilot
  Cowork picks skills up at the start of the next conversation, after OneDrive uploads. Claude
  Code picks up live file changes.

## The description is the routing key

The frontmatter `description` is the ONLY thing either tool's router sees before invocation.
Both tools inject the skill list (name + description) into context and match requests against it;
both truncate from the END under budget pressure (Codex caps the whole list at ~2% of context /
8k chars), so front-load the core use case and trigger words.

Template:

```yaml
---
name: verb-first-lowercase-hyphens
description: <What it does, third person, systems named>. Use when the user asks
  <literal phrases they type>, or mentions <domain nouns, filename patterns>.
  <One lane-defining line vs overlapping sibling skills.>
---
```

Rules, all mechanically checkable:

1. Never name a host tool. "Use when Codex needs..." reads as "not for me" when Claude Code loads
   the mirrored copy, and "with Claude in Chrome" does the same on Codex. Write "Use when the
   user asks..."; state optional tooling as "when available, otherwise <fallback>".
2. Quote literal user utterances ("package X for Intune", "check on LAPTOP-123"), not a content
   inventory of the body. The best performers in this set (create-fedex-label,
   analyze-vulnerability-kpis) are the models to copy.
3. Stay under 1,024 characters, core use case in the first sentence.
4. If a sibling skill shares trigger nouns, add one lane-defining line to each (e.g. ssh-access
   = interactive shell over Cato; screenconnect-remote-diagnostics = API-driven read-only diagnostics).
   The it-operations umbrella intentionally overlaps all specialists — it declares its router
   role in its own description; don't "fix" that overlap.

## Body rules — must run cold in either tool

- Skill-relative paths for bundled assets: "`scripts/check.ps1` inside this skill's folder",
  never `~/.codex/skills/...` or `~/.claude/skills/...` absolute paths.
- Cross-reference sibling skills by plain name ("use the screenconnect-remote-diagnostics skill"),
  never the Codex-only `$skill` sigil.
- Tool-neutral runtimes and fallbacks: "any Python 3, e.g. `py -3`", not "the bundled Codex
  Python runtime". Scheduling guidance must cover both tools or stay generic.
- Approval gates for production systems (Intune, ScreenConnect, Automox, Graph, Freshservice
  writes) stated inside the body, so a cold session inherits the guardrail.
- Facts: a fact lives in exactly one place. Embed a fact in the body only if this skill alone
  needs it to run cold; shared facts go to memory or the umbrella skill, referenced from here.
  When a shared fact changes, grep every SKILL.md for the old value before calling the update done.
- Volatile state: anything with a date, version number, URL, or the word "currently" gets a
  "verified YYYY-MM-DD" tag, and pointers to dated artifacts say "the newest <pattern> in <place>"
  with the current one as a known-good example — never a dated file as the only pointer.
- No secrets, ever: reference the Keeper/KSM record or env-file path instead.
- Size: keep SKILL.md to roughly one screen of runbook spine; push detail into `references/`
  files inside the skill folder. Split into a sibling only when two user intents can no longer
  share one honest description.

## Post-write checklist

Run these before reporting the skill done:

1. Frontmatter YAML parses; file is exactly `SKILL.md` (Codex discovery silently skips
   `SKILL.MD` — case matters).
2. Description under 1,024 chars, trigger words in the first sentence.
3. Grep the file for: `Codex`, `Claude`, `$` sigil skill references, `~/.codex`, `~/.claude`,
   dated URLs/filenames, and key/token/password patterns. Each hit must be intentional.
4. Re-run the sync (same command as the session-start sync) and confirm the Claude/Codex
   mirror plus a `COWORK` copy in `~/.ai-sync/sync.log`.
5. Report in one line what was captured or changed.

When touching an existing skill for any reason, fix tool-named phrasing, `$` sigils, and
tool-home paths in the lines being edited; note any remaining violations in one line rather than
rewriting the whole file unprompted.

## Discovery troubleshooting (skill exists but never fires)

Distinguish routing failure (skill visible, not chosen — fix the description per the rules above)
from discovery failure (skill not in the tool's list at all). For discovery (verified 2026-07-01):

- Codex: the sync script maintains `~/.agents/skills` automatically — one directory junction per
  skill pointing at the `~/.claude/skills` copy, never a link on the parent directory (which
  Codex silently ignores, openai/codex#11314). That mirror is write-only: fix a skill in
  `~/.claude/skills` or `~/.codex/skills`, never in `~/.agents/skills`; deleting a skill from an
  authoritative side removes its junction on the next sync. Codex docs now document only
  `~/.agents/skills`, but the build installed here (26.730.8199.0 as of 2026-08-05) still
  reads `~/.codex/skills` only and has no `codex --list-skills`; enumerate instead with
  `codex exec "Reply with only the names of the skills available to you"`. If a skill is missing
  there, check its folder + `SKILL.md` exist under `~/.codex/skills` and that its junction in
  `~/.agents/skills` resolves. Known regressions: openai/codex#15136, #15939. Restart Codex
  after skill changes if they don't appear.
- Claude Code: the agent cannot run `/skills` itself — verify the folder exists on disk and ask
  the user to run `/skills` to confirm the list.
- Cursor: the sync maintains `~/.cursor/skills` the same way as `~/.agents/skills` — one
  junction per skill into `~/.claude/skills`. Edits made from Cursor write through. Built-in
  skills under `~/.cursor/skills-cursor/` are Cursor's own and are not mirrored.
- Copilot Cowork: the sync copies real files (not junctions) to OneDrive
  `Documents/Cowork/skills/<name>/SKILL.md`. Cowork discovers custom skills at the start of
  each conversation (verified 2026-08-15 against Microsoft Learn: up to 50 custom skills,
  1 MB per SKILL.md). OneDrive does not upload reparse points, which is why this path is a
  copy rather than a junction. Edits made in Cowork do not sync back; a new Cowork session
  is needed after OneDrive has uploaded. If a skill is missing there, confirm the folder
  exists under the Windows Documents known folder (on this machine that is the Contoso
  OneDrive Documents path) and that `SKILL.md` is present, then wait for OneDrive to finish
  syncing.
- Both coding tools shorten descriptions, then drop skills entirely, when the skill list exceeds
  its context budget. If the list looks thinner than the folder on disk, that is the budget, not a
  bug: consolidate — merge sibling skills covering one workflow, delete superseded ones (the sync
  backs up before honoring deletions), and rewrite any description near the 1,024-char limit from
  scratch rather than trimming it.

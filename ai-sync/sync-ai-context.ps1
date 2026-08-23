<#
.SYNOPSIS
  Bidirectional, newest-wins sync of AI assistant context between Claude Code (~/.claude)
  and OpenAI Codex (~/.codex): skills, global guidance, and project memory.

.DESCRIPTION
  For every file in a managed area, the newer copy (by LastWriteTimeUtc) is mirrored to the
  other side. Identical files are skipped. Before any existing file is overwritten it is
  backed up under ~/.ai-sync/backups/<timestamp>.

  DELETIONS: handled via a state manifest (~/.ai-sync/state.json). A file that existed on
  both sides last run, is unchanged on the surviving side, and is now gone from the other is
  treated as an intentional deletion: it is backed up, then removed from the surviving side
  (recoverable from the backup). A file that is genuinely new on one side (not in the prior
  manifest) is copied across. A file edited on the surviving side is copied across (kept), not
  deleted. So a deletion you make in one tool is honored on the next sync instead of being
  resurrected, and nothing is ever destroyed without a backup.

  Managed areas:
    1. Skills   : ~/.claude/skills/<name>/         <->  ~/.codex/skills/<name>/
                  (Codex ".system" + dot-folders excluded. A minimal agents/openai.yaml is
                   scaffolded on the Codex side for any skill that lacks one, so Codex lists it.)
    2. Guidance : ~/.claude/CLAUDE.md              <->  ~/.codex/AGENTS.md
    3. Memory   : ~/.claude/projects/<slug>/memory  <->  ~/.codex/memory/<slug>/
                  (slugs are matched by identical folder name; both tools must use the same scheme.)

  Cursor (write-only consumer, NOT a third peer):
    ~/.cursor/skills/<name>  = per-folder junction -> ~/.claude/skills/<name>, same mechanism and
                               same safety rules as the agents mirror below. Edits made from
                               Cursor land in ~/.claude/skills and sync onward normally.
    ~/.cursor/mcp.json       = ONE-WAY projection of the canonical MCP set. A server added inside
                               Cursor is NOT read back: the two-way rule needs a per-side manifest
                               to tell an intentional deletion from a not-yet-synced addition, and
                               Cursor has none here. Add servers in Claude Code or Codex.
    Global guidance and project memory are NOT synced to Cursor. Cursor's global equivalent of
    CLAUDE.md is User Rules, which lives in Cursor's internal state rather than a file, so there
    is nothing to mirror to; project memory has no Cursor-side store of the same shape.
    Skipped entirely when ~/.cursor does not exist.

  Copilot Cowork (write-only consumer, NOT a third peer):
    <Documents>/Cowork/skills/<name>/  = REAL FILE COPY of each personal skill (not a junction).
                               Documents is the Windows known folder, which on this machine is
                               the OneDrive-backed path Copilot Cowork reads
                               (/Documents/Cowork/skills/<name>/SKILL.md). Junctions are not used
                               here because OneDrive does not upload reparse points, and Cowork
                               discovers skills from the cloud copy at the start of each
                               conversation. Codex-only agents/openai.yaml is omitted.
                               Edits made in Cowork do not sync back. Skills created only in
                               Cowork (names that were never projected) are left alone. A skill
                               deleted from both Claude and Codex is removed from Cowork on the
                               next sync (backed up first). Microsoft cap: 50 custom skills,
                               1 MB per SKILL.md. Skipped if the Documents folder is missing.

  Agents mirror (write-only, NOT a managed area):
    ~/.agents/skills/<name>  = per-folder directory junction -> ~/.claude/skills/<name>
    Codex's documented personal-skills path moved to ~/.agents/skills (~/.codex/skills still
    works in current builds but is no longer documented). One junction PER SKILL, never for the
    parent directory (a linked parent is silently ignored — openai/codex#11314). The mirror is
    one-way: ~/.agents/skills is never scanned by Sync-Tree and never enters the state manifest,
    so nothing placed there syncs back and junctions can never be misread as deletions. Edits
    made THROUGH a junction land in ~/.claude/skills (the junction is the same folder) and sync
    normally. Junctions whose skill disappeared from both authoritative sides are removed —
    removing a junction deletes no content, only the pointer. Real (non-junction) folders found
    in ~/.agents/skills are user content: never touched, warned on name collision.

.PARAMETER DryRun
  Report what would change; write nothing (and do not update the manifest).

.PARAMETER Quiet
  Suppress per-file INFO output (used by the SessionStart hook). Warnings/errors still print.

.NOTES
  Safe to run repeatedly. Log + backups + state under ~/.ai-sync. Uses $env:USERPROFILE so it
  is portable. Compatible with Windows PowerShell 5.1 and PowerShell 7.
  Managed trees must not contain directory junctions/symlinks (reparse points are skipped).
  The junctions this script creates live only under ~/.agents/skills and ~/.cursor/skills,
  outside every managed tree. The Cowork mirror is real files under OneDrive Documents.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Quiet,

  # Resolve an MCP stand-off by declaring one tool authoritative for this run. Needed the first
  # time the two tools already disagree (no manifest exists yet to say which side changed), and
  # any time both were edited between syncs.
  [ValidateSet('claude', 'codex')]
  [string]$McpWinner = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Roots -------------------------------------------------------------------
$UserHome     = $env:USERPROFILE
$ClaudeHome   = Join-Path $UserHome '.claude'
$CodexHome    = Join-Path $UserHome '.codex'
$AgentsSkills = Join-Path $UserHome '.agents\skills'
$CursorHome   = Join-Path $UserHome '.cursor'
$CursorSkills = Join-Path $CursorHome 'skills'
$CursorMcp    = Join-Path $CursorHome 'mcp.json'
$DocumentsRoot = [Environment]::GetFolderPath('MyDocuments')
$CoworkSkills  = if ($DocumentsRoot) { Join-Path $DocumentsRoot 'Cowork\skills' } else { $null }
$SyncHome     = Join-Path $UserHome '.ai-sync'
$CoworkMirrorState = Join-Path $SyncHome 'cowork-mirror.json'
$BackupRoot   = Join-Path $SyncHome 'backups'
$LogFile      = Join-Path $SyncHome 'sync.log'
$StateFile    = Join-Path $SyncHome 'state.json'
$Stamp        = (Get-Date).ToString('yyyyMMdd-HHmmss')
$TimeToleranceSec = 5
$HandoffMaxAgeHours = 24

$ExcludeDirNames  = @('.system','.git','node_modules','__pycache__','.tmp','backups','.venv','.ipynb_checkpoints')
$ExcludeFileGlobs = @('*.pyc','*.tmp','*.lock','*.log','desktop.ini','Thumbs.db')

$script:Counts   = @{ Copied = 0; Conflicts = 0; Scaffolded = 0; Deleted = 0; Mirrored = 0; Errors = 0; McpConflicts = 0 }
$script:Manifest    = @{}   # prior run state: key -> { hash, mtime }
$script:NewManifest = @{}   # state to persist this run

if (-not (Test-Path -LiteralPath $SyncHome)) { New-Item -ItemType Directory -Force -Path $SyncHome | Out-Null }

# --- Helpers -----------------------------------------------------------------
function Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('s'), $Level, $Message
  if (-not $Quiet -or $Level -ne 'INFO') {
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
  }
  try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop } catch { }
}

function Get-FullPathSafe {
  param([string]$Path)
  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Get-ManagedFiles {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  $rootFull = Get-FullPathSafe $Root
  Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }   # skip symlinked files / junctions
    $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\','/')
    $segments = $rel -split '[\\/]'
    $dirSegments = @($segments | Select-Object -SkipLast 1)
    foreach ($d in $dirSegments) { if ($ExcludeDirNames -contains $d) { return $false } }
    foreach ($g in $ExcludeFileGlobs) { if ($_.Name -like $g) { return $false } }
    return $true
  }
}

function Backup-File {
  param([string]$Path)
  if ($DryRun) { return }
  $rel  = $Path -replace '^[A-Za-z]:[\\/]', ''
  $dest = Join-Path (Join-Path $BackupRoot $Stamp) $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  Copy-Item -LiteralPath $Path -Destination $dest -Force
}

function Copy-File {
  param([string]$Src, [string]$Dst)
  if ($DryRun) { return }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dst) | Out-Null
  Copy-Item -LiteralPath $Src -Destination $Dst -Force
  # Copy-Item stamps Dst with 'now'; carry the source mtime so newest-wins stays truthful and runs converge.
  (Get-Item -LiteralPath $Dst).LastWriteTimeUtc = (Get-Item -LiteralPath $Src).LastWriteTimeUtc
}

function Get-Hash {
  param([string]$Path)
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Record-State {
  param([string]$Key, [string]$Path)
  if (-not $Key) { return }
  try {
    $script:NewManifest[$Key] = @{
      hash  = (Get-Hash $Path)
      mtime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString('o')
    }
  } catch { }
}

function Sync-Pair {
  param([string]$A, [string]$B, [string]$Key)
  try {
    $ae = Test-Path -LiteralPath $A -PathType Leaf
    $be = Test-Path -LiteralPath $B -PathType Leaf
    if (-not $ae -and -not $be) { return }

    # --- One side only: deletion vs new file, decided by the prior manifest ---
    if ($ae -xor $be) {
      $present = if ($ae) { $A } else { $B }
      $absent  = if ($ae) { $B } else { $A }
      $priorHash = $null
      if ($Key -and $script:Manifest.ContainsKey($Key)) {
        $entry = $script:Manifest[$Key]
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'hash')) { $priorHash = $entry.hash }
      }
      if ($priorHash -and $priorHash -eq (Get-Hash $present)) {
        # Was synced before, unchanged on the surviving side, removed on the other -> honor deletion (recoverable).
        Log "DELETE (removal propagated, backed up) : $present" 'WARN'
        Backup-File $present
        if (-not $DryRun) { Remove-Item -LiteralPath $present -Force }
        $script:Counts.Deleted++
        # Key intentionally left out of NewManifest: file now absent on both sides.
      }
      else {
        # Genuinely new (not in manifest) or edited-on-surviving-side -> copy across (safe; never deletes an edit).
        Log "NEW  $present  ->  $absent"
        Copy-File $present $absent
        $script:Counts.Copied++
        Record-State $Key $present
      }
      return
    }

    # --- Both sides exist ---
    if ((Get-Hash $A) -eq (Get-Hash $B)) { Record-State $Key $A; return }   # identical content

    $ta = (Get-Item -LiteralPath $A).LastWriteTimeUtc
    $tb = (Get-Item -LiteralPath $B).LastWriteTimeUtc
    $diff = ($ta - $tb).TotalSeconds
    if ([math]::Abs($diff) -le $TimeToleranceSec) {
      Log "CONFLICT (different content, ~equal time) — both copies backed up, left for manual review: $A  <->  $B" 'WARN'
      Backup-File $A
      Backup-File $B
      $script:Counts.Conflicts++
      return
    }
    if ($diff -gt 0) { Log "UPD  A->B : $B"; Backup-File $B; Copy-File $A $B; $script:Counts.Copied++; Record-State $Key $A }
    else             { Log "UPD  B->A : $A"; Backup-File $A; Copy-File $B $A; $script:Counts.Copied++; Record-State $Key $B }
  }
  catch {
    Log "ERROR pair `"$A`" <-> `"$B`" : $($_.Exception.Message)" 'ERROR'
    $script:Counts.Errors++
  }
}

function Sync-Tree {
  param([string]$RootA, [string]$RootB, [string]$KeyPrefix)
  $rels = @{}
  $aFull = Get-FullPathSafe $RootA
  $bFull = Get-FullPathSafe $RootB
  foreach ($f in Get-ManagedFiles $aFull) { $rels[$f.FullName.Substring($aFull.Length).TrimStart('\','/')] = $true }
  foreach ($f in Get-ManagedFiles $bFull) { $rels[$f.FullName.Substring($bFull.Length).TrimStart('\','/')] = $true }
  foreach ($rel in $rels.Keys) {
    $key = $KeyPrefix + '/' + ($rel -replace '\\','/')
    Sync-Pair (Join-Path $aFull $rel) (Join-Path $bFull $rel) $key
  }
}

function Get-Frontmatter {
  param([string]$Path)
  $res = @{}
  $inFm = $false
  foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
    if ($line -match '^---\s*$') { if (-not $inFm) { $inFm = $true; continue } else { break } }
    if ($inFm -and $line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$') { $res[$matches[1]] = $matches[2].Trim() }
  }
  return $res
}

# Codex shows a skill in its menu via agents/openai.yaml. Claude-origin skills lack it, so
# scaffold a minimal one from the SKILL.md frontmatter.
function Add-MissingCodexSkillYaml {
  $codexSkills = Join-Path $CodexHome 'skills'
  if (-not (Test-Path -LiteralPath $codexSkills)) { return }
  Get-ChildItem -LiteralPath $codexSkills -Directory -Force | Where-Object { $_.Name -notlike '.*' } | ForEach-Object {
    $skillMd = Join-Path $_.FullName 'SKILL.md'
    $yaml    = Join-Path $_.FullName 'agents\openai.yaml'
    if ((Test-Path -LiteralPath $skillMd) -and -not (Test-Path -LiteralPath $yaml)) {
      try {
        $fm = Get-Frontmatter $skillMd
        if (-not $fm.ContainsKey('name') -or [string]::IsNullOrWhiteSpace($fm['name'])) { return }
        $name  = $fm['name']
        $disp  = (Get-Culture).TextInfo.ToTitleCase(($name -replace '[-_]', ' '))
        $short = if ($fm.ContainsKey('description') -and $fm['description']) { ($fm['description'] -split '(?<=[.!?])\s', 2)[0] } else { $name }
        if ($short.Length -gt 100) { $short = $short.Substring(0, 97) + '...' }
        $disp  = $disp  -replace '"', "'"
        $short = $short -replace '"', "'"
        $content = @"
interface:
  display_name: "$disp"
  short_description: "$short"
  default_prompt: "Use `$$name to get started."
"@
        if (-not $DryRun) {
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $yaml) | Out-Null
          # BOM-less UTF-8 (Set-Content -Encoding UTF8 emits a BOM on PS 5.1, which breaks YAML parsers).
          [System.IO.File]::WriteAllText($yaml, $content, (New-Object System.Text.UTF8Encoding($false)))
        }
        Log "SCAFFOLD Codex openai.yaml for skill '$($_.Name)'"
        $script:Counts.Scaffolded++
      }
      catch {
        Log "ERROR scaffolding openai.yaml for '$($_.Name)': $($_.Exception.Message)" 'ERROR'
        $script:Counts.Errors++
      }
    }
  }
}

# Reads a reparse point's stored target. PS 5.1 exposes .Target as a collection, PS 7 as a
# string (and 7.2+ also has .LinkTarget); normalize to one plain path, without any \\?\ prefix.
function Get-JunctionTarget {
  param($Item)
  $raw = $null
  $p = $Item.PSObject.Properties['Target']
  if ($p -and $p.Value) { $raw = @($p.Value)[0] }
  if (-not $raw) {
    $p = $Item.PSObject.Properties['LinkTarget']
    if ($p -and $p.Value) { $raw = $p.Value }
  }
  if (-not $raw) { return $null }
  return ([string]$raw) -replace '^\\\\\?\\', ''
}

# Union of personal skill folders across Claude and Codex. Claude wins when both have the same
# name (junctions and the Cowork copy both target this path). Dot-folders, reparse points, and
# directories without SKILL.md are not skills (empty husks left by file-level deletion stay out).
function Get-AuthoritativeSkillFolders {
  $sources = @{}
  foreach ($root in @((Join-Path $ClaudeHome 'skills'), (Join-Path $CodexHome 'skills'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -notlike '.*' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
      ($ExcludeDirNames -notcontains $_.Name) -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf)
    } | ForEach-Object {
      if (-not $sources.ContainsKey($_.Name)) { $sources[$_.Name] = $_.FullName }
    }
  }
  return $sources
}

# Codex's documented personal-skills path is now ~/.agents/skills. Mirror every synced skill
# there as a per-folder junction to its ~/.claude/skills copy (fallback: ~/.codex/skills).
# Write-only: this tree is never scanned by Sync-Tree and never enters the manifest, so nothing
# here syncs back or reads as a deletion. Only entries that are reparse points targeting one of
# the two authoritative skill roots are managed; anything else in the folder is left alone.
function Update-SkillsMirror {
  param([Parameter(Mandatory)][string]$MirrorRoot)
  $skillRoots = @((Join-Path $ClaudeHome 'skills'), (Join-Path $CodexHome 'skills'))
  $rootFulls  = @($skillRoots | ForEach-Object { Get-FullPathSafe $_ })
  $sources    = Get-AuthoritativeSkillFolders
  if ($null -eq $sources) { $sources = @{} }

  $existing = @{}
  if (Test-Path -LiteralPath $MirrorRoot) {
    Get-ChildItem -LiteralPath $MirrorRoot -Directory -Force -ErrorAction SilentlyContinue |
      ForEach-Object { $existing[$_.Name] = $_ }
  }
  elseif ($sources.Count -eq 0) { return }

  foreach ($name in @($sources.Keys)) {
    try {
      $link   = Join-Path $MirrorRoot $name
      $target = $sources[$name]
      if ($existing.ContainsKey($name)) {
        $item = $existing[$name]
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
          Log "MIRROR skip '$name': a real folder already exists at $link — user content, left untouched (authoritative copies unaffected)" 'WARN'
          continue
        }
        $cur = Get-JunctionTarget $item
        if ($cur -and ((Get-FullPathSafe $cur) -ieq (Get-FullPathSafe $target))) { continue }   # already correct
        Log "MIRROR retarget : $link -> $target (was: $cur)"
        if (-not $DryRun) {
          [System.IO.Directory]::Delete($link)   # removes only the junction, never the target's content
          New-Item -ItemType Junction -Path $link -Value $target | Out-Null
        }
        $script:Counts.Mirrored++
      }
      else {
        Log "MIRROR junction : $link -> $target"
        if (-not $DryRun) {
          New-Item -ItemType Directory -Force -Path $MirrorRoot | Out-Null
          New-Item -ItemType Junction -Path $link -Value $target | Out-Null
        }
        $script:Counts.Mirrored++
      }
    }
    catch {
      Log "ERROR mirroring skill '$name' into ${MirrorRoot}: $($_.Exception.Message)" 'ERROR'
      $script:Counts.Errors++
    }
  }

  # Drop junctions whose skill is gone from both authoritative sides. Junction removal deletes
  # no content (the pointer only), so no backup is needed; the log line records the old target.
  foreach ($name in @($existing.Keys)) {
    if ($sources.ContainsKey($name)) { continue }
    $item = $existing[$name]
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }   # user's own folder
    $cur = Get-JunctionTarget $item
    $managed = $false
    if ($cur) {
      $curFull = Get-FullPathSafe $cur
      foreach ($rf in $rootFulls) { if ($curFull -like ($rf + '\*')) { $managed = $true } }
    }
    if (-not $managed) { continue }   # points elsewhere or unreadable — not ours, leave it
    try {
      Log "MIRROR remove junction (skill deleted) : $($item.FullName) (was -> $cur)" 'WARN'
      if (-not $DryRun) { [System.IO.Directory]::Delete($item.FullName) }
      $script:Counts.Mirrored++
    }
    catch {
      Log "ERROR removing stale junction '$name': $($_.Exception.Message)" 'ERROR'
      $script:Counts.Errors++
    }
  }
}

# ====================== Copilot Cowork projection (one-way) =====================
# Copilot Cowork loads custom skills from OneDrive /Documents/Cowork/skills/<name>/SKILL.md
# at the start of each conversation (Microsoft cap: 50 custom skills, 1 MB per SKILL.md).
# This tree is a CONSUMER, not a third peer: real files are copied here after Claude <-> Codex
# reconcile, never scanned by Sync-Tree, and never enter the file-state manifest. Junctions are
# not used — OneDrive does not upload reparse points, and Cowork reads the cloud copy.
# Codex-only agents/openai.yaml is omitted. Skills created only in Cowork (names this script
# has never projected) are left alone. A skill this script previously copied, then deleted from
# both Claude and Codex, is backed up and removed from Cowork on the next run.
$CoworkSkillLimit      = 50
$CoworkSkillMdMaxBytes = 1MB

function Get-CoworkDestFiles {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  $rootFull = Get-FullPathSafe $Root
  Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\','/')
    $segments = $rel -split '[\\/]'
    $dirSegments = @($segments | Select-Object -SkipLast 1)
    foreach ($d in $dirSegments) { if ($ExcludeDirNames -contains $d) { return $false } }
    foreach ($g in $ExcludeFileGlobs) { if ($_.Name -like $g) { return $false } }
    return $true
  }
}

function Publish-TreeOneWay {
  param(
    [Parameter(Mandatory)][string]$SrcRoot,
    [Parameter(Mandatory)][string]$DstRoot,
    [string[]]$SkipTopDirs = @('agents')
  )
  $srcFull  = Get-FullPathSafe $SrcRoot
  $srcFiles = @{}
  foreach ($f in Get-ManagedFiles $srcFull) {
    $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\','/')
    $top = ($rel -split '[\\/]')[0]
    if ($SkipTopDirs -contains $top) { continue }
    $srcFiles[$rel] = $f.FullName
  }

  $dstFiles = @{}
  if (Test-Path -LiteralPath $DstRoot) {
    $dstFull = Get-FullPathSafe $DstRoot
    foreach ($f in Get-CoworkDestFiles $dstFull) {
      $rel = $f.FullName.Substring($dstFull.Length).TrimStart('\','/')
      $dstFiles[$rel] = $f.FullName
    }
  }

  foreach ($rel in @($srcFiles.Keys)) {
    $src  = $srcFiles[$rel]
    $dst  = Join-Path $DstRoot $rel
    $need = $true
    if ($dstFiles.ContainsKey($rel)) {
      try { if ((Get-Hash $src) -eq (Get-Hash $dstFiles[$rel])) { $need = $false } } catch { $need = $true }
    }
    if (-not $need) { continue }
    if ($dstFiles.ContainsKey($rel)) {
      Log "COWORK UPD  $dst"
      Backup-File $dstFiles[$rel]
    }
    else {
      Log "COWORK NEW  $dst"
    }
    Copy-File $src $dst
    $script:Counts.Mirrored++
  }

  foreach ($rel in @($dstFiles.Keys)) {
    if ($srcFiles.ContainsKey($rel)) { continue }
    Log "COWORK DELETE extra : $($dstFiles[$rel])" 'WARN'
    Backup-File $dstFiles[$rel]
    if (-not $DryRun) { Remove-Item -LiteralPath $dstFiles[$rel] -Force }
    $script:Counts.Deleted++
  }
}

function Remove-CoworkSkillFolder {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Log "COWORK remove junction : $Path" 'WARN'
    if (-not $DryRun) { [System.IO.Directory]::Delete($Path) }
    $script:Counts.Deleted++
    return
  }
  foreach ($f in Get-CoworkDestFiles $Path) { Backup-File $f.FullName }
  Log "COWORK DELETE skill folder : $Path" 'WARN'
  if (-not $DryRun) { Remove-Item -LiteralPath $Path -Recurse -Force }
  $script:Counts.Deleted++
}

function Update-CoworkSkillsMirror {
  if ([string]::IsNullOrWhiteSpace($DocumentsRoot) -or -not (Test-Path -LiteralPath $DocumentsRoot)) {
    Log "Cowork skills mirror skipped: Documents folder not found" 'WARN'
    return
  }
  if ([string]::IsNullOrWhiteSpace($CoworkSkills)) { return }

  $sources = Get-AuthoritativeSkillFolders
  if ($null -eq $sources) { $sources = @{} }

  $prior = @()
  if (Test-Path -LiteralPath $CoworkMirrorState -PathType Leaf) {
    try {
      $loaded = Get-Content -LiteralPath $CoworkMirrorState -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($loaded -and $loaded.PSObject.Properties.Name -contains 'projected' -and $loaded.projected) {
        $prior = @($loaded.projected | ForEach-Object { [string]$_ })
      }
    }
    catch { Log "Could not read $CoworkMirrorState (treating as first Cowork projection): $($_.Exception.Message)" 'WARN' }
  }

  $existing = @{}
  if (Test-Path -LiteralPath $CoworkSkills) {
    Get-ChildItem -LiteralPath $CoworkSkills -Directory -Force -ErrorAction SilentlyContinue |
      ForEach-Object { $existing[$_.Name] = $_ }
  }

  foreach ($name in @($sources.Keys)) {
    try {
      $src = $sources[$name]
      $dst = Join-Path $CoworkSkills $name
      $skillMd = Join-Path $src 'SKILL.md'
      $mdLen = (Get-Item -LiteralPath $skillMd).Length
      if ($mdLen -gt $CoworkSkillMdMaxBytes) {
        Log ("COWORK SKILL.md for '{0}' is {1} bytes (Cowork cap is 1 MB) — copying anyway" -f $name, $mdLen) 'WARN'
      }
      if (Test-Path -LiteralPath $dst) {
        $item = Get-Item -LiteralPath $dst -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
          Log "COWORK replace junction with real copy : $dst"
          if (-not $DryRun) { [System.IO.Directory]::Delete($dst) }
        }
      }
      Publish-TreeOneWay $src $dst
    }
    catch {
      Log "ERROR projecting skill '$name' into Cowork: $($_.Exception.Message)" 'ERROR'
      $script:Counts.Errors++
    }
  }

  $priorSet = @{}
  foreach ($n in $prior) { if ($n) { $priorSet[$n] = $true } }
  foreach ($name in @($priorSet.Keys)) {
    if ($sources.ContainsKey($name)) { continue }
    $dst = Join-Path $CoworkSkills $name
    if (-not (Test-Path -LiteralPath $dst)) { continue }
    try { Remove-CoworkSkillFolder $dst }
    catch {
      Log "ERROR removing Cowork copy of deleted skill '$name': $($_.Exception.Message)" 'ERROR'
      $script:Counts.Errors++
    }
  }

  if (Test-Path -LiteralPath $CoworkSkills) {
    $custom = @(Get-ChildItem -LiteralPath $CoworkSkills -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf })
    if ($custom.Count -gt $CoworkSkillLimit) {
      Log ("COWORK custom skill count is {0} (Microsoft cap is {1}) — Cowork may ignore extras" -f $custom.Count, $CoworkSkillLimit) 'WARN'
    }
  }

  if ($DryRun) { return }

  New-Item -ItemType Directory -Force -Path $CoworkSkills | Out-Null
  $readme = Join-Path $CoworkSkills 'README.md'
  $note = @"
# Copilot Cowork skills (write-only mirror)

Projected by ``~/.ai-sync/sync-ai-context.ps1`` from the personal skills in
``~/.claude/skills`` (and ``~/.codex/skills``). Copilot Cowork reads
``/Documents/Cowork/skills/<name>/SKILL.md`` from this OneDrive folder at the
start of each conversation.

Do not edit skills here expecting them to flow back. Edit in Claude Code, Codex,
or Cursor, then re-run the context sync. Skills created only in Cowork (folder
names that do not match a mirrored skill) are left alone.
"@
  [System.IO.File]::WriteAllText($readme, $note, (New-Object System.Text.UTF8Encoding($false)))

  $persist = [ordered]@{
    updated   = (Get-Date).ToString('o')
    projected = @($sources.Keys | Sort-Object)
  }
  ($persist | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $CoworkMirrorState -Encoding UTF8
}

# =============================== MCP servers ==================================
# Claude Code keeps user-scope MCP servers in ~/.claude.json ("mcpServers"); Codex keeps them in
# ~/.codex/config.toml ([mcp_servers.<name>]). ~/.ai-sync/mcp-servers.json is both the canonical
# set and the state manifest, so the deletion rule matches the file sync: a server unchanged on
# the surviving side and gone from the other was deleted on purpose, not lost.
#
# Two things are deliberately NOT propagated:
#   - Servers a tool injects for itself (Codex's node_repl, anything under the Codex runtimes
#     directory). They point at tool-private binaries and are meaningless to the other side.
#   - Literal secret values in `env`. A secret-looking key whose value is not a reference
#     (keeper://, ${...}, $env:, %VAR%) is stored as a sentinel and each tool keeps whatever it
#     already had, so this file never becomes a new place secrets live.

$McpFile    = Join-Path $SyncHome 'mcp-servers.json'
$ClaudeJson = Join-Path $UserHome '.claude.json'
$CodexToml  = Join-Path $CodexHome 'config.toml'

$SecretKeyPattern  = '(?i)(key|token|secret|password|passwd|pwd|credential|auth)'
$SafeRefPattern    = '^(keeper://|\$\{|\$env:|%[A-Za-z_])'
$PreserveSentinel  = '__ai_sync_preserve__'
$CodexRuntimeHint  = '\OpenAI\Codex\runtimes\'
$DefaultMcpIgnore  = @('node_repl')

function ConvertTo-HashtableDeep {
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in $Obj.Keys) { $h[[string]$k] = ConvertTo-HashtableDeep $Obj[$k] }
    return $h
  }
  if ($Obj -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    return $h
  }
  if ($Obj -is [object[]]) { return @($Obj | ForEach-Object { ConvertTo-HashtableDeep $_ }) }
  return $Obj
}

function Test-EnvValueSyncSafe {
  param([string]$Name, [string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return $true }
  if ($Name -notmatch $SecretKeyPattern) { return $true }
  return ($Value -match $SafeRefPattern)
}

# A server is either local (command/args/env over stdio) or remote (a url spoken over Streamable
# HTTP, with the tool handling OAuth itself). 'url' non-empty is what makes it remote; the two
# forms are mutually exclusive and every writer below branches on Test-McpServerIsRemote.
function New-McpServerShape {
  return @{ command = ''; args = @(); env = @{}; url = ''; claudeOnly = @{}; codexOnly = @{} }
}

function Test-McpServerIsRemote {
  param($Def)
  if ($null -eq $Def) { return $false }
  if ($Def -is [System.Collections.IDictionary]) {
    return ($Def.Contains('url') -and -not [string]::IsNullOrWhiteSpace([string]$Def['url']))
  }
  return $false
}

# Only command/args/env/url decide whether two definitions agree; per-tool extras (Claude's "type",
# Codex's startup_timeout_sec) are carried through untouched and never cause a false conflict.
function Get-McpComparable {
  param($Def)
  $envPairs = @()
  if ($Def.env) {
    foreach ($k in @($Def.env.Keys | Sort-Object)) { $envPairs += ('{0}={1}' -f $k, [string]$Def.env[$k]) }
  }
  $u = ''
  if ($Def -is [System.Collections.IDictionary] -and $Def.Contains('url')) { $u = [string]$Def['url'] }
  return ('cmd={0}|args={1}|env={2}|url={3}' -f [string]$Def.command, (@($Def.args) -join "`u{1}"), ($envPairs -join "`u{1}"), $u)
}

# ---- TOML (read) -------------------------------------------------------------
function Remove-TomlComment {
  param([string]$Text)
  $out = ''; $inStr = $false; $q = ''; $esc = $false
  foreach ($ch in $Text.ToCharArray()) {
    if ($inStr) {
      $out += $ch
      if ($esc) { $esc = $false; continue }
      if ($ch -eq '\' -and $q -eq '"') { $esc = $true; continue }
      if ($ch -eq $q) { $inStr = $false }
      continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $inStr = $true; $q = $ch; $out += $ch; continue }
    if ($ch -eq '#') { break }
    $out += $ch
  }
  return $out
}

function Get-BracketBalance {
  param([string]$Text)
  $bal = 0; $inStr = $false; $q = ''; $esc = $false
  foreach ($ch in $Text.ToCharArray()) {
    if ($inStr) {
      if ($esc) { $esc = $false; continue }
      if ($ch -eq '\' -and $q -eq '"') { $esc = $true; continue }
      if ($ch -eq $q) { $inStr = $false }
      continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $inStr = $true; $q = $ch; continue }
    if ($ch -eq '#') { break }
    if ($ch -eq '[') { $bal++ }
    elseif ($ch -eq ']') { $bal-- }
  }
  return $bal
}

function ConvertFrom-TomlScalar {
  param([string]$Raw)
  $s = (Remove-TomlComment $Raw).Trim()
  if ($s.Length -ge 2 -and $s.StartsWith("'") -and $s.EndsWith("'")) { return $s.Substring(1, $s.Length - 2) }
  if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) {
    $inner = $s.Substring(1, $s.Length - 2)
    $out = ''; $i = 0
    while ($i -lt $inner.Length) {
      if ($inner[$i] -eq '\' -and $i + 1 -lt $inner.Length) {
        $n = $inner[$i + 1]
        switch ($n) {
          'n'  { $out += "`n" }
          'r'  { $out += "`r" }
          't'  { $out += "`t" }
          '"'  { $out += '"'  }
          '\'  { $out += '\'  }
          default { $out += ('\' + $n) }
        }
        $i += 2; continue
      }
      $out += $inner[$i]; $i++
    }
    return $out
  }
  if ($s -eq 'true')  { return $true }
  if ($s -eq 'false') { return $false }
  $n = 0
  if ([int]::TryParse($s, [ref]$n)) { return $n }
  return $s
}

function ConvertFrom-TomlArray {
  param([string]$Raw)
  $t = $Raw.Trim()
  $open = $t.IndexOf('['); $close = $t.LastIndexOf(']')
  if ($open -lt 0 -or $close -le $open) { return @() }
  $inner = $t.Substring($open + 1, $close - $open - 1)
  $items = @(); $cur = ''; $inStr = $false; $q = ''; $esc = $false; $depth = 0
  foreach ($ch in $inner.ToCharArray()) {
    if ($inStr) {
      $cur += $ch
      if ($esc) { $esc = $false; continue }
      if ($ch -eq '\' -and $q -eq '"') { $esc = $true; continue }
      if ($ch -eq $q) { $inStr = $false }
      continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $inStr = $true; $q = $ch; $cur += $ch; continue }
    if ($ch -eq '[') { $depth++; $cur += $ch; continue }
    if ($ch -eq ']') { $depth--; $cur += $ch; continue }
    if ($ch -eq ',' -and $depth -eq 0) {
      if ($cur.Trim()) { $items += ,(ConvertFrom-TomlScalar $cur) }
      $cur = ''; continue
    }
    $cur += $ch
  }
  if ($cur.Trim()) { $items += ,(ConvertFrom-TomlScalar $cur) }
  return ,$items
}

function Split-TomlSections {
  param([string[]]$Lines)
  $sections = New-Object System.Collections.ArrayList
  $cur = @{ Header = $null; Name = ''; Lines = (New-Object System.Collections.ArrayList) }
  foreach ($line in $Lines) {
    $m = [regex]::Match($line, '^\s*\[([^\[\]]+)\]\s*(#.*)?$')
    if ($m.Success) {
      [void]$sections.Add($cur)
      $cur = @{ Header = $line; Name = $m.Groups[1].Value.Trim(); Lines = (New-Object System.Collections.ArrayList) }
    }
    else { [void]$cur.Lines.Add($line) }
  }
  [void]$sections.Add($cur)
  return $sections
}

function Read-TomlKeyValues {
  param($Lines)
  $kv = [ordered]@{}
  $buf = $null; $key = $null
  foreach ($line in $Lines) {
    if ($null -ne $buf) {
      $buf += "`n" + $line
      if ((Get-BracketBalance $buf) -le 0) { $kv[$key] = ConvertFrom-TomlArray $buf; $buf = $null; $key = $null }
      continue
    }
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $m = [regex]::Match($t, '^([A-Za-z0-9_\-\."'']+)\s*=\s*(.*)$')
    if (-not $m.Success) { continue }
    $k = $m.Groups[1].Value.Trim('"', "'")
    $v = $m.Groups[2].Value
    if ($v.TrimStart().StartsWith('[')) {
      if ((Get-BracketBalance $v) -gt 0) { $key = $k; $buf = $v; continue }
      $kv[$k] = ConvertFrom-TomlArray $v; continue
    }
    $kv[$k] = ConvertFrom-TomlScalar $v
  }
  return $kv
}

function Get-CodexMcpServers {
  $result = @{}
  if (-not (Test-Path -LiteralPath $CodexToml)) { return $result }
  $sections = Split-TomlSections ([System.IO.File]::ReadAllLines($CodexToml))
  foreach ($sec in $sections) {
    $m = [regex]::Match([string]$sec.Name, '^mcp_servers\.(.+)$')
    if (-not $m.Success) { continue }
    $rest  = $m.Groups[1].Value
    $parts = $rest -split '\.', 2
    $name  = $parts[0].Trim('"', "'")
    $sub   = ''
    if ($parts.Count -gt 1) { $sub = $parts[1] }
    if (-not $result.ContainsKey($name)) { $result[$name] = New-McpServerShape }
    $kv = Read-TomlKeyValues $sec.Lines
    if ($sub -eq 'env') {
      foreach ($k in $kv.Keys) { $result[$name].env[$k] = [string]$kv[$k] }
    }
    elseif ($sub -eq '') {
      foreach ($k in $kv.Keys) {
        if     ($k -eq 'command') { $result[$name].command = [string]$kv[$k] }
        elseif ($k -eq 'args')    { $result[$name].args    = @($kv[$k]) }
        elseif ($k -eq 'url')     { $result[$name].url     = [string]$kv[$k] }
        else                      { $result[$name].codexOnly[$k] = $kv[$k] }
      }
    }
  }
  return $result
}

# ---- TOML (write) ------------------------------------------------------------
function ConvertTo-TomlString {
  param([string]$Value)
  if ($Value -notmatch "'" -and $Value -notmatch '[\r\n]') { return "'" + $Value + "'" }
  $e = $Value -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n'
  return '"' + $e + '"'
}

# Emits a TOML array from a PowerShell array without the extra nesting level you get from
# passing the array through a scalar-shaped parameter.
function ConvertTo-TomlArrayLiteral {
  param([object[]]$Items)
  if ($null -eq $Items -or $Items.Count -eq 0) { return '[]' }
  return '[' + ((@($Items) | ForEach-Object { ConvertTo-TomlValue $_ }) -join ', ') + ']'
}

function ConvertTo-TomlValue {
  param($Value)
  if ($Value -is [bool])   { if ($Value) { return 'true' } else { return 'false' } }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
  if ($Value -is [object[]]) {
    if (@($Value).Count -eq 0) { return '[]' }
    return '[' + ((@($Value) | ForEach-Object { ConvertTo-TomlValue $_ }) -join ', ') + ']'
  }
  return ConvertTo-TomlString ([string]$Value)
}

function Format-CodexMcpSection {
  param([string]$Name, $Def)
  $key = $Name
  if ($Name -notmatch '^[A-Za-z0-9_-]+$') { $key = '"' + $Name + '"' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("[mcp_servers.$key]")
  if (Test-McpServerIsRemote $Def) {
    # Codex speaks Streamable HTTP from a bare url; `codex mcp login` drives the OAuth dance.
    [void]$sb.AppendLine("url = $(ConvertTo-TomlString ([string]$Def.url))")
  }
  else {
    [void]$sb.AppendLine("command = $(ConvertTo-TomlString ([string]$Def.command))")
    [void]$sb.AppendLine("args = $(ConvertTo-TomlArrayLiteral @($Def.args))")
  }
  if ($Def.codexOnly) {
    foreach ($k in @($Def.codexOnly.Keys | Sort-Object)) {
      [void]$sb.AppendLine("$k = $(ConvertTo-TomlValue $Def.codexOnly[$k])")
    }
  }
  if ($Def.env -and @($Def.env.Keys).Count -gt 0) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("[mcp_servers.$key.env]")
    foreach ($k in @($Def.env.Keys | Sort-Object)) {
      [void]$sb.AppendLine("$k = $(ConvertTo-TomlString ([string]$Def.env[$k]))")
    }
  }
  return $sb.ToString()
}

function Set-CodexMcpServers {
  param($Upsert, $Remove)
  if (-not (Test-Path -LiteralPath $CodexToml)) { return }
  $touched = @{}
  foreach ($n in @($Upsert.Keys)) { $touched[$n] = $true }
  foreach ($n in @($Remove))      { $touched[$n] = $true }
  if ($touched.Count -eq 0) { return }

  $sections = Split-TomlSections ([System.IO.File]::ReadAllLines($CodexToml))
  $sb = New-Object System.Text.StringBuilder
  foreach ($sec in $sections) {
    $drop = $false
    $m = [regex]::Match([string]$sec.Name, '^mcp_servers\.([^.]+)')
    if ($m.Success) {
      $n = $m.Groups[1].Value.Trim('"', "'")
      if ($touched.ContainsKey($n)) { $drop = $true }
    }
    if ($drop) { continue }
    if ($null -ne $sec.Header) { [void]$sb.AppendLine([string]$sec.Header) }
    foreach ($l in $sec.Lines) { [void]$sb.AppendLine([string]$l) }
  }
  $text = $sb.ToString().TrimEnd() + "`n"
  foreach ($n in @($Upsert.Keys | Sort-Object)) {
    $text += "`n" + (Format-CodexMcpSection $n $Upsert[$n])
  }
  Backup-File $CodexToml
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($CodexToml, $text, (New-Object System.Text.UTF8Encoding($false)))
  }
}

# ---- Claude .claude.json (surgical splice) -----------------------------------
# .claude.json is a large live file Claude Code rewrites constantly. Reserializing the whole
# document risks quiet damage, so only the "mcpServers" value span is replaced; every other byte
# is preserved. The result is parsed before it is written.
function Get-JsonValueEnd {
  param([string]$Text, [int]$Start)
  $len = $Text.Length
  $i = $Start
  if ($i -ge $len) { return -1 }
  $c = $Text[$i]
  if ($c -eq '"') {
    $i++
    while ($i -lt $len) {
      if ($Text[$i] -eq '\') { $i += 2; continue }
      if ($Text[$i] -eq '"') { return $i + 1 }
      $i++
    }
    return -1
  }
  if ($c -eq '{' -or $c -eq '[') {
    $depth = 0
    while ($i -lt $len) {
      $ch = $Text[$i]
      if ($ch -eq '"') {
        $i++
        while ($i -lt $len) {
          if ($Text[$i] -eq '\') { $i += 2; continue }
          if ($Text[$i] -eq '"') { break }
          $i++
        }
        $i++; continue
      }
      if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
      elseif ($ch -eq '}' -or $ch -eq ']') { $depth--; if ($depth -eq 0) { return $i + 1 } }
      $i++
    }
    return -1
  }
  while ($i -lt $len) {
    $ch = $Text[$i]
    if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']') { break }
    $i++
  }
  return $i
}

function Find-JsonTopLevelValueSpan {
  param([string]$Text, [string]$Key)
  $len = $Text.Length
  $i = 0
  while ($i -lt $len -and $Text[$i] -ne '{') { $i++ }
  if ($i -ge $len) { return $null }
  $i++
  while ($i -lt $len) {
    $c = $Text[$i]
    if ($c -eq '}') { return $null }
    if ($c -ne '"') { $i++; continue }
    $strStart = $i
    $i++
    while ($i -lt $len) {
      if ($Text[$i] -eq '\') { $i += 2; continue }
      if ($Text[$i] -eq '"') { break }
      $i++
    }
    $name = $Text.Substring($strStart + 1, $i - $strStart - 1)
    $i++
    while ($i -lt $len -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $len -or $Text[$i] -ne ':') { continue }
    $i++
    while ($i -lt $len -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    $vEnd = Get-JsonValueEnd $Text $i
    if ($vEnd -lt 0) { return $null }
    if ($name -eq $Key) { return @{ ValueStart = $i; ValueEnd = $vEnd } }
    $i = $vEnd
  }
  return $null
}

function Get-ClaudeMcpServers {
  $result = @{}
  if (-not (Test-Path -LiteralPath $ClaudeJson)) { return $result }
  $raw  = [System.IO.File]::ReadAllText($ClaudeJson)
  $span = Find-JsonTopLevelValueSpan $raw 'mcpServers'
  if (-not $span) { return $result }
  $obj = $raw.Substring($span.ValueStart, $span.ValueEnd - $span.ValueStart) | ConvertFrom-Json
  foreach ($p in $obj.PSObject.Properties) {
    $def = New-McpServerShape
    $v = $p.Value
    foreach ($vp in $v.PSObject.Properties) {
      if     ($vp.Name -eq 'command') { $def.command = [string]$vp.Value }
      elseif ($vp.Name -eq 'args')    { $def.args    = @($vp.Value) }
      elseif ($vp.Name -eq 'url')     { $def.url     = [string]$vp.Value }
      elseif ($vp.Name -eq 'env')     { if ($vp.Value) { foreach ($e in $vp.Value.PSObject.Properties) { $def.env[$e.Name] = [string]$e.Value } } }
      else                            { $def.claudeOnly[$vp.Name] = $vp.Value }
    }
    $result[$p.Name] = $def
  }
  return $result
}

function Set-ClaudeMcpServers {
  param($Servers)
  if (-not (Test-Path -LiteralPath $ClaudeJson)) { return }
  $out = [ordered]@{}
  foreach ($n in @($Servers.Keys | Sort-Object)) {
    $d = $Servers[$n]
    $entry = [ordered]@{}
    $isRemote = Test-McpServerIsRemote $d
    if ($d.claudeOnly -and $d.claudeOnly.ContainsKey('type')) { $entry['type'] = $d.claudeOnly['type'] }
    elseif ($isRemote) { $entry['type'] = 'http' }
    else { $entry['type'] = 'stdio' }
    if ($isRemote) {
      # Remote servers carry no command/args; Claude Code handles the OAuth handshake itself.
      $entry['url'] = [string]$d.url
    }
    else {
      $entry['command'] = [string]$d.command
      $entry['args']    = @($d.args)
      if ($d.env -and @($d.env.Keys).Count -gt 0) {
        $e = [ordered]@{}
        foreach ($k in @($d.env.Keys | Sort-Object)) { $e[$k] = [string]$d.env[$k] }
        $entry['env'] = $e
      }
    }
    if ($d.claudeOnly) {
      foreach ($k in @($d.claudeOnly.Keys | Sort-Object)) {
        if ($k -eq 'type') { continue }
        $entry[$k] = $d.claudeOnly[$k]
      }
    }
    $out[$n] = $entry
  }
  $json = ConvertTo-Json $out -Depth 20
  if (@($out.Keys).Count -eq 0) { $json = '{}' }

  $raw  = [System.IO.File]::ReadAllText($ClaudeJson)
  $span = Find-JsonTopLevelValueSpan $raw 'mcpServers'
  if ($span) {
    $new = $raw.Substring(0, $span.ValueStart) + $json + $raw.Substring($span.ValueEnd)
  }
  else {
    $b = $raw.IndexOf('{')
    if ($b -lt 0) { throw 'Unrecognized .claude.json structure' }
    $new = $raw.Substring(0, $b + 1) + "`n  `"mcpServers`": " + $json + ',' + $raw.Substring($b + 1)
  }
  $null = $new | ConvertFrom-Json   # refuse to write anything that does not parse
  Backup-File $ClaudeJson
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($ClaudeJson, $new, (New-Object System.Text.UTF8Encoding($false)))
  }
}

# ---- Reconcile ---------------------------------------------------------------
function Sync-McpServers {
  try {
    $canon  = @{ ignore = @{ claude = @(); codex = $DefaultMcpIgnore }; servers = @{} }
    if (Test-Path -LiteralPath $McpFile) {
      try {
        $loaded = ConvertTo-HashtableDeep (Get-Content -LiteralPath $McpFile -Raw | ConvertFrom-Json)
        # Normalize every entry to a full New-McpServerShape on the way in. Straight off disk these
        # are plain hashtables holding only the keys that were persisted, so an entry with no env
        # (or no claudeOnly/codexOnly) makes Get-McpComparable and the persist loop throw under
        # Set-StrictMode -Version Latest. Normalizing here keeps every downstream consumer safe.
        if ($loaded -and $loaded.ContainsKey('servers') -and $loaded['servers']) {
          foreach ($sname in @($loaded['servers'].Keys)) {
            $canon.servers[$sname] = ConvertTo-McpShape $loaded['servers'][$sname]
          }
        }
        if ($loaded -and $loaded.ContainsKey('ignore')  -and $loaded['ignore'])  { $canon.ignore  = $loaded['ignore'] }
      }
      catch { Log "Could not read $McpFile (starting from what the tools have): $($_.Exception.Message)" 'WARN' }
    }
    foreach ($side in @('claude', 'codex')) {
      if (-not $canon.ignore.ContainsKey($side)) { $canon.ignore[$side] = @() }
    }

    $claude = Get-ClaudeMcpServers
    $codex  = Get-CodexMcpServers

    # A server a tool spawns from its own runtime tree is tool-private; never offer it to the other.
    foreach ($n in @($codex.Keys)) {
      if ([string]$codex[$n].command -like "*$CodexRuntimeHint*" -and @($canon.ignore['codex']) -notcontains $n) {
        $canon.ignore['codex'] = @($canon.ignore['codex']) + $n
        Log "MCP ignore '$n' on codex (tool-private runtime binary)"
      }
    }

    $names = @{}
    foreach ($n in @($claude.Keys)) { if (@($canon.ignore['claude']) -notcontains $n) { $names[$n] = $true } }
    foreach ($n in @($codex.Keys))  { if (@($canon.ignore['codex'])  -notcontains $n) { $names[$n] = $true } }
    foreach ($n in @($canon.servers.Keys)) { $names[$n] = $true }

    $claudeUpsert = @{}; $codexUpsert = @{}; $codexRemove = @()
    $changed = $false; $claudeDirty = $false

    foreach ($name in @($names.Keys)) {
      $inClaude = $claude.ContainsKey($name) -and (@($canon.ignore['claude']) -notcontains $name)
      $inCodex  = $codex.ContainsKey($name)  -and (@($canon.ignore['codex'])  -notcontains $name)
      $prior    = $null
      if ($canon.servers.ContainsKey($name)) { $prior = $canon.servers[$name] }

      if (-not $inClaude -and -not $inCodex) {
        if ($prior) { $canon.servers.Remove($name); $changed = $true; Log "MCP forget '$name' (absent from both tools)" }
        continue
      }

      # One side only: deletion if the survivor still matches what was last synced, else propagate.
      if ($inClaude -xor $inCodex) {
        $survivor = if ($inClaude) { $claude[$name] } else { $codex[$name] }
        if ($prior -and (Get-McpComparable $prior) -eq (Get-McpComparable $survivor)) {
          Log "MCP DELETE '$name' (removal propagated; previous definition kept in $McpFile backup)" 'WARN'
          if ($inClaude) { $claude.Remove($name); $claudeDirty = $true } else { $codexRemove += $name }
          $canon.servers.Remove($name)
          $changed = $true
          $script:Counts.Deleted++
          continue
        }
        $canon.servers[$name] = $survivor
        $changed = $true
        if ($inClaude) { $codexUpsert[$name]  = $survivor; Log "MCP NEW  '$name' claude -> codex" }
        else           { $claudeUpsert[$name] = $survivor; Log "MCP NEW  '$name' codex -> claude" }
        continue
      }

      # Both sides present.
      $cl = $claude[$name]; $cx = $codex[$name]
      if ((Get-McpComparable $cl) -eq (Get-McpComparable $cx)) {
        if (-not $prior -or (Get-McpComparable $prior) -ne (Get-McpComparable $cl)) { $canon.servers[$name] = $cl; $changed = $true }
        continue
      }
      $clDiff = (-not $prior) -or ((Get-McpComparable $prior) -ne (Get-McpComparable $cl))
      $cxDiff = (-not $prior) -or ((Get-McpComparable $prior) -ne (Get-McpComparable $cx))
      if ($clDiff -and $cxDiff) {
        if ($McpWinner -eq 'claude') { $canon.servers[$name] = $cl; $codexUpsert[$name]  = $cl; $changed = $true; Log "MCP RESOLVE '$name' -> claude wins (-McpWinner)"; continue }
        if ($McpWinner -eq 'codex')  { $canon.servers[$name] = $cx; $claudeUpsert[$name] = $cx; $changed = $true; Log "MCP RESOLVE '$name' -> codex wins (-McpWinner)";  continue }
        Log "MCP CONFLICT '$name': the two tools disagree and no manifest says which side changed. Re-run with -McpWinner claude|codex to pick." 'WARN'
        $script:Counts.McpConflicts++
        continue
      }
      if ($clDiff) { $canon.servers[$name] = $cl; $codexUpsert[$name]  = $cl; $changed = $true; Log "MCP UPD  '$name' claude -> codex" }
      else         { $canon.servers[$name] = $cx; $claudeUpsert[$name] = $cx; $changed = $true; Log "MCP UPD  '$name' codex -> claude" }
    }

    # Apply, restoring any env value the canonical set refuses to carry.
    if (@($claudeUpsert.Keys).Count -gt 0 -or $claudeDirty) {
      foreach ($n in @($claudeUpsert.Keys)) {
        $existing = $null
        if ($claude.ContainsKey($n)) { $existing = $claude[$n] }
        $claude[$n] = Resolve-McpEnvForTarget $claudeUpsert[$n] $existing $n 'Claude Code'
      }
      Set-ClaudeMcpServers $claude
      $script:Counts.Copied += @($claudeUpsert.Keys).Count
    }
    if (@($codexUpsert.Keys).Count -gt 0 -or $codexRemove.Count -gt 0) {
      $resolved = @{}
      foreach ($n in @($codexUpsert.Keys)) {
        $existing = $null
        if ($codex.ContainsKey($n)) { $existing = $codex[$n] }
        $resolved[$n] = Resolve-McpEnvForTarget $codexUpsert[$n] $existing $n 'Codex'
      }
      Set-CodexMcpServers $resolved $codexRemove
      $script:Counts.Copied += @($resolved.Keys).Count
    }

    if ($changed -and -not $DryRun) {
      $safeServers = [ordered]@{}
      foreach ($n in @($canon.servers.Keys | Sort-Object)) {
        # Belt and braces: entries are normalized at load, but a shape here is cheap and idempotent.
        $d = ConvertTo-McpShape $canon.servers[$n]
        $entry = [ordered]@{}
        if (Test-McpServerIsRemote $d) { $entry['url'] = [string]$d.url }
        else { $entry['command'] = [string]$d.command; $entry['args'] = @($d.args) }
        $e = [ordered]@{}
        if ($d.env) {
          foreach ($k in @($d.env.Keys | Sort-Object)) {
            $v = [string]$d.env[$k]
            if (Test-EnvValueSyncSafe $k $v) { $e[$k] = $v }
            else { $e[$k] = $PreserveSentinel }
          }
        }
        if (@($e.Keys).Count -gt 0) { $entry['env'] = $e }
        if ($d.claudeOnly -and @($d.claudeOnly.Keys).Count -gt 0) { $entry['claudeOnly'] = $d.claudeOnly }
        if ($d.codexOnly  -and @($d.codexOnly.Keys).Count  -gt 0) { $entry['codexOnly']  = $d.codexOnly }
        $safeServers[$n] = $entry
      }
      $persist = [ordered]@{
        '_comment' = "Canonical MCP servers shared by Claude Code and Codex, and the state manifest that makes deletions stick. Edit here to change both tools, then re-run sync-ai-context.ps1. Values equal to '$PreserveSentinel' are secret-looking env vars deliberately not stored here — each tool keeps its own."
        'ignore'   = $canon.ignore
        'servers'  = $safeServers
      }
      if (Test-Path -LiteralPath $McpFile) { Backup-File $McpFile }
      ($persist | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $McpFile -Encoding UTF8
    }

    # Cursor is downstream of the reconcile, not part of it: project the settled set into it.
    Update-CursorMcpProjection $canon.servers
  }
  catch {
    Log "ERROR syncing MCP servers: $($_.Exception.Message)" 'ERROR'
    $script:Counts.Errors++
  }
}

# A secret-looking env value that is not a reference never leaves the tool that holds it: the
# canonical copy stores a sentinel and the target keeps its own value (or is flagged if it has none).
function Resolve-McpEnvForTarget {
  param($Def, $Existing, [string]$Name, [string]$TargetLabel)
  $out = New-McpServerShape
  $out.command    = $Def.command
  $out.args       = @($Def.args)
  $out.url        = [string]$Def.url
  $out.claudeOnly = $Def.claudeOnly
  $out.codexOnly  = $Def.codexOnly
  if ($Existing) {
    if ($Existing.claudeOnly -and @($Existing.claudeOnly.Keys).Count -gt 0) { $out.claudeOnly = $Existing.claudeOnly }
    if ($Existing.codexOnly  -and @($Existing.codexOnly.Keys).Count  -gt 0) { $out.codexOnly  = $Existing.codexOnly }
  }
  if ($Def.env) {
    foreach ($k in @($Def.env.Keys)) {
      $v = [string]$Def.env[$k]
      if ($v -ne $PreserveSentinel) { $out.env[$k] = $v; continue }
      if ($Existing -and $Existing.env -and $Existing.env.ContainsKey($k)) { $out.env[$k] = [string]$Existing.env[$k]; continue }
      Log "MCP '$Name': env '$k' holds a literal secret and is not copied between tools — set it manually in $TargetLabel" 'WARN'
    }
  }
  return $out
}

# ========================= Cursor projection (one-way) ========================
# Cursor is a CONSUMER of the shared context, not a third peer in the reconcile above.
#
# Skills reach it as per-skill junctions into ~/.cursor/skills, using the same mechanism and the
# same safety rules as the ~/.agents/skills mirror. A skill edited from inside Cursor therefore
# writes through to ~/.claude/skills and syncs onward normally — there is no second copy to
# diverge, and nothing under ~/.cursor ever enters the state manifest.
#
# MCP is different: it is projected ONE WAY from the canonical set into ~/.cursor/mcp.json. A
# server added or edited inside Cursor is NOT picked up. Two-way would need a per-side manifest
# to tell "deleted on purpose" from "not there yet" — the reconcile above is built entirely on
# that distinction — and Cursor has no such state here. Add or change servers in Claude Code or
# Codex and they land in Cursor on the next sync.
#
# Secret handling matches the other two tools: a canonical env value held as the preserve
# sentinel is never written literally. Cursor keeps whatever it already had for that key, or the
# key is dropped with a warning. This file never becomes a new place secrets live.
function Get-CursorMcpServers {
  $out = @{}
  if (-not (Test-Path -LiteralPath $CursorMcp -PathType Leaf)) { return $out }
  try {
    $obj = ConvertTo-HashtableDeep (Get-Content -LiteralPath $CursorMcp -Raw | ConvertFrom-Json)
    if (-not $obj -or -not $obj.ContainsKey('mcpServers') -or -not $obj['mcpServers']) { return $out }
    foreach ($n in @($obj['mcpServers'].Keys)) {
      $d = $obj['mcpServers'][$n]
      if (-not ($d -is [System.Collections.IDictionary])) { continue }
      $shape = New-McpServerShape
      if ($d.ContainsKey('command')) { $shape.command = [string]$d['command'] }
      if ($d.ContainsKey('args') -and $d['args']) { $shape.args = @($d['args']) }
      if ($d.ContainsKey('url')) { $shape.url = [string]$d['url'] }
      if ($d.ContainsKey('env') -and $d['env']) {
        foreach ($k in @($d['env'].Keys)) { $shape.env[$k] = [string]$d['env'][$k] }
      }
      $out[$n] = $shape
    }
  }
  catch { Log "Could not read $CursorMcp (leaving Cursor's MCP config alone): $($_.Exception.Message)" 'WARN' }
  return $out
}

# Canonical entries reloaded from mcp-servers.json only carry the keys that were persisted
# (claudeOnly/codexOnly/env are written only when non-empty), whereas every entry produced during
# the reconcile is a full New-McpServerShape. Under Set-StrictMode -Version Latest, reading an
# absent key off the partial ones throws "The property 'claudeOnly' cannot be found on this
# object". Fill the shape out before handing it to code that expects all five keys.
function ConvertTo-McpShape {
  param($Def)
  $s = New-McpServerShape
  if ($null -eq $Def) { return $s }
  if (-not ($Def -is [System.Collections.IDictionary])) { return $Def }
  if ($Def.Contains('command')) { $s.command = [string]$Def['command'] }
  if ($Def.Contains('args') -and $Def['args']) { $s.args = @($Def['args']) }
  if ($Def.Contains('url')) { $s.url = [string]$Def['url'] }
  if ($Def.Contains('env') -and $Def['env']) {
    foreach ($k in @($Def['env'].Keys)) { $s.env[$k] = [string]$Def['env'][$k] }
  }
  if ($Def.Contains('claudeOnly') -and $Def['claudeOnly']) { $s.claudeOnly = $Def['claudeOnly'] }
  if ($Def.Contains('codexOnly')  -and $Def['codexOnly'])  { $s.codexOnly  = $Def['codexOnly'] }
  return $s
}

function Update-CursorMcpProjection {
  param($CanonServers)
  try {
    if (-not (Test-Path -LiteralPath $CursorHome)) { return }   # Cursor not installed on this box
    $current = Get-CursorMcpServers

    $desiredShapes = @{}
    $desired       = [ordered]@{}
    foreach ($n in @($CanonServers.Keys | Sort-Object)) {
      $existing = $null
      if ($current.ContainsKey($n)) { $existing = $current[$n] }
      $r = Resolve-McpEnvForTarget (ConvertTo-McpShape $CanonServers[$n]) $existing $n 'Cursor'
      $desiredShapes[$n] = $r
      if (Test-McpServerIsRemote $r) {
        # Cursor speaks Streamable HTTP natively and runs the OAuth flow on first use.
        $entry = [ordered]@{ type = 'http'; url = [string]$r.url }
      }
      else {
        $entry = [ordered]@{ command = [string]$r.command; args = @($r.args) }
        if (@($r.env.Keys).Count -gt 0) {
          $e = [ordered]@{}
          foreach ($k in @($r.env.Keys | Sort-Object)) { $e[$k] = [string]$r.env[$k] }
          $entry['env'] = $e
        }
      }
      $desired[$n] = $entry
    }

    # Compare on the same command/args/env basis the reconcile uses, so extras Cursor adds of its
    # own accord never trigger a rewrite-every-run loop.
    $same = (@($desired.Keys).Count -eq @($current.Keys).Count)
    if ($same) {
      foreach ($n in @($desired.Keys)) {
        if (-not $current.ContainsKey($n)) { $same = $false; break }
        if ((Get-McpComparable $desiredShapes[$n]) -ne (Get-McpComparable $current[$n])) { $same = $false; break }
      }
    }
    if ($same) { return }

    Log ("MCP project -> Cursor: {0} server(s) into {1}" -f @($desired.Keys).Count, $CursorMcp)
    if ($DryRun) { return }

    # Replace only mcpServers; any other top-level key Cursor keeps in this file survives.
    $root = [ordered]@{}
    if (Test-Path -LiteralPath $CursorMcp -PathType Leaf) {
      try {
        $existingRoot = Get-Content -LiteralPath $CursorMcp -Raw | ConvertFrom-Json
        foreach ($p in $existingRoot.PSObject.Properties) {
          if ($p.Name -ne 'mcpServers') { $root[$p.Name] = $p.Value }
        }
      }
      catch { Log "Existing $CursorMcp did not parse — backed up, and being replaced." 'WARN' }
      Backup-File $CursorMcp
    }
    $root['mcpServers'] = $desired

    $json = $root | ConvertTo-Json -Depth 20
    $null = $json | ConvertFrom-Json   # refuse to write anything that does not parse
    [System.IO.File]::WriteAllText($CursorMcp, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:Counts.Mirrored++
  }
  catch {
    Log "ERROR projecting MCP servers into Cursor: $($_.Exception.Message)" 'ERROR'
    $script:Counts.Errors++
  }
}

# ===================== Codex global memory -> Claude ==========================
# Codex generates a global memory store (~/.codex/memories) that Claude Code has no equivalent of.
# Mirror the readable summaries one way so a Claude session can grep what Codex already learned.
function Update-CodexMemoryBridge {
  try {
    $src = Join-Path $CodexHome 'memories'
    if (-not (Test-Path -LiteralPath $src)) { return }
    $dst = Join-Path $ClaudeHome 'memory\codex-global'
    foreach ($file in @('memory_summary.md', 'MEMORY.md')) {
      $s = Join-Path $src $file
      if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { continue }
      $d = Join-Path $dst $file
      if ((Test-Path -LiteralPath $d) -and (Get-Hash $s) -eq (Get-Hash $d)) { continue }
      Log "BRIDGE codex memories -> $d"
      Copy-File $s $d
      $script:Counts.Mirrored++
    }
    if (-not $DryRun -and (Test-Path -LiteralPath $dst)) {
      $readme = Join-Path $dst 'README.md'
      $note = @"
# Codex global memory (read-only mirror)

Codex maintains an automatic global memory store at ``~/.codex/memories``. Claude Code has no
equivalent, so ``sync-ai-context.ps1`` copies the two readable files here one way:

- ``memory_summary.md`` — short digest, cheap to read in full.
- ``MEMORY.md`` — the full store; grep it, do not read it whole.

Codex owns these files and regenerates them. Edits here are overwritten on the next sync — to
record a durable fact both tools should share, write it to the per-project memory store instead
(``~/.claude/projects/<slug>/memory/``, mirrored to ``~/.codex/memory/<slug>/``).
"@
      [System.IO.File]::WriteAllText($readme, $note, (New-Object System.Text.UTF8Encoding($false)))
    }
  }
  catch {
    Log "ERROR bridging Codex memories: $($_.Exception.Message)" 'ERROR'
    $script:Counts.Errors++
  }
}

# ============================ Handoff surfacing ===============================
# Printed on stdout even under -Quiet: Claude Code feeds SessionStart hook output into the session,
# and Codex reads the command result, so one active note reaches whichever tool opens next.
function Show-ActiveHandoff {
  try {
    $file = Join-Path $SyncHome 'handoff\HANDOFF.md'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $raw = [System.IO.File]::ReadAllText($file)
    $written = (Get-Item -LiteralPath $file).LastWriteTime
    $from = 'unknown'
    $m = [regex]::Match($raw, '(?s)^\s*---\r?\n(.*?)\r?\n---\r?\n?')
    if ($m.Success) {
      foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
        $kv = [regex]::Match($line, '^\s*(from|written)\s*:\s*(.*)$')
        if (-not $kv.Success) { continue }
        if ($kv.Groups[1].Value -eq 'from') { $from = $kv.Groups[2].Value.Trim() }
        else { try { $written = [datetime]::Parse($kv.Groups[2].Value.Trim()) } catch { } }
      }
    }
    $age = ((Get-Date) - $written).TotalHours
    if ($age -gt $HandoffMaxAgeHours) {
      Log ("Handoff from '{0}' is {1:N1}h old (past {2}h) — not surfaced. Archive it with handoff.ps1 -Clear." -f $from, $age, $HandoffMaxAgeHours) 'WARN'
      return
    }
    Write-Host ''
    Write-Host '=== ACTIVE HANDOFF — another AI tool left this task in progress ===' -ForegroundColor Cyan
    Write-Host ("(from '{0}', {1:N1}h ago)" -f $from, $age) -ForegroundColor Cyan
    Write-Host ''
    Write-Host $raw
    Write-Host '=== end handoff — pick the task up here. When it is done, run: ===' -ForegroundColor Cyan
    Write-Host ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Clear' -f (Join-Path $SyncHome 'handoff.ps1')) -ForegroundColor Cyan
    Write-Host ''
  }
  catch { Log "Could not read handoff note: $($_.Exception.Message)" 'WARN' }
}

# --- Main --------------------------------------------------------------------
try {
  if (-not (Test-Path -LiteralPath $ClaudeHome) -and -not (Test-Path -LiteralPath $CodexHome)) {
    Log "Neither $ClaudeHome nor $CodexHome exists — nothing to sync." 'WARN'
    return
  }
  Log ("=== sync start{0} ===" -f $(if ($DryRun) { ' (DRY RUN)' } else { '' }))

  # Load prior-run manifest (for deletion detection).
  if (Test-Path -LiteralPath $StateFile) {
    try {
      $obj = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
      foreach ($p in $obj.PSObject.Properties) { $script:Manifest[$p.Name] = $p.Value }
    } catch {
      Log "Could not read state manifest (treating all one-sided files as new): $($_.Exception.Message)" 'WARN'
      $script:Manifest = @{}
    }
  }

  # 1. Guidance
  Sync-Pair (Join-Path $ClaudeHome 'CLAUDE.md') (Join-Path $CodexHome 'AGENTS.md') 'guidance'

  # 2. Skills
  Sync-Tree (Join-Path $ClaudeHome 'skills') (Join-Path $CodexHome 'skills') 'skills'
  Add-MissingCodexSkillYaml
  Update-SkillsMirror $AgentsSkills
  if (Test-Path -LiteralPath $CursorHome) { Update-SkillsMirror $CursorSkills }
  Update-CoworkSkillsMirror

  # 3. Memory (per project slug)
  $claudeProjects = Join-Path $ClaudeHome 'projects'
  $codexMemRoot   = Join-Path $CodexHome 'memory'
  $slugs = @{}
  if (Test-Path -LiteralPath $claudeProjects) {
    Get-ChildItem -LiteralPath $claudeProjects -Directory -Force | ForEach-Object {
      if (Test-Path -LiteralPath (Join-Path $_.FullName 'memory')) { $slugs[$_.Name] = $true }
    }
  }
  if (Test-Path -LiteralPath $codexMemRoot) {
    Get-ChildItem -LiteralPath $codexMemRoot -Directory -Force | ForEach-Object { $slugs[$_.Name] = $true }
  }
  foreach ($slug in $slugs.Keys) {
    Sync-Tree (Join-Path $claudeProjects (Join-Path $slug 'memory')) (Join-Path $codexMemRoot $slug) ("memory/$slug")
  }

  # 4. Codex's global auto-memory, mirrored one way so Claude can read it too.
  Update-CodexMemoryBridge

  # 5. MCP servers (own manifest in mcp-servers.json, not the file state above).
  Sync-McpServers

  # Persist manifest for next run's deletion detection (skip on dry run).
  if (-not $DryRun) {
    try { ($script:NewManifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
    catch { Log "Could not write state manifest: $($_.Exception.Message)" 'WARN' }
  }

  Log ("=== done: {0} copied, {1} deleted, {2} scaffolded, {3} mirrored, {4} conflicts, {5} mcp-conflicts, {6} errors ===" -f `
        $script:Counts.Copied, $script:Counts.Deleted, $script:Counts.Scaffolded, $script:Counts.Mirrored, `
        $script:Counts.Conflicts, $script:Counts.McpConflicts, $script:Counts.Errors)
  if ($script:Counts.Conflicts -gt 0) {
    Log "Conflicts: files differed with near-equal timestamps; both versions are in the backup folder. Edit the intended one and re-run." 'WARN'
  }
  if ($script:Counts.McpConflicts -gt 0) {
    Log "MCP conflicts: nothing was changed in either tool. Re-run with -McpWinner claude|codex once you know which definition is right." 'WARN'
  }
}
catch {
  # Never throw out of a SessionStart hook — log and exit cleanly.
  Log "FATAL: $($_.Exception.Message)" 'ERROR'
}

# Last, and outside the try: a sync failure must never swallow an in-progress handoff.
Show-ActiveHandoff

<#
.SYNOPSIS
  Hand the current task from one AI coding tool to another (Claude Code <-> Codex <-> Cursor).

.DESCRIPTION
  Writes a single active handoff note to ~/.ai-sync/handoff/HANDOFF.md. The context-sync script
  (sync-ai-context.ps1) prints that note at the start of every session in every tool, so the next
  tool you open resumes with the task state instead of a cold start.

  One handoff is active at a time. Writing a new one archives the previous. Reading does not
  consume it (both tools may start after one handoff); clear it when the work is done, or let it
  age out (the sync stops showing notes older than -MaxAgeHours, default 24).

.PARAMETER Write
  Create/replace the active handoff. Body text comes from -BodyFile (preferred for multi-line
  notes) or -Body.

.PARAMETER Show
  Print the active handoff. Exits 1 if none is active.

.PARAMETER Clear
  Archive the active handoff and mark the work done.

.PARAMETER Status
  One-line status. Exits 0 if a handoff is active, 1 if not.

.EXAMPLE
  .\handoff.ps1 -Write -From codex -Title "Cato reg fix" -BodyFile .\note.md
.EXAMPLE
  .\handoff.ps1 -Write -From claude -Body "Next: verify the pilot ring picked up the worklet."

.NOTES
  No pipeline-bound parameters on purpose: a script invoked as `powershell -File` that declares
  ValueFromPipeline blocks waiting on stdin. Agents should write the body to a temp file and pass
  -BodyFile.
#>
[CmdletBinding(DefaultParameterSetName = 'Show')]
param(
  [Parameter(ParameterSetName = 'Write',  Mandatory = $true)][switch]$Write,
  [Parameter(ParameterSetName = 'Show')]                     [switch]$Show,
  [Parameter(ParameterSetName = 'Clear',  Mandatory = $true)][switch]$Clear,
  [Parameter(ParameterSetName = 'Status', Mandatory = $true)][switch]$Status,

  [Parameter(ParameterSetName = 'Write')][string]$From     = '',
  [Parameter(ParameterSetName = 'Write')][string]$Title    = '',
  [Parameter(ParameterSetName = 'Write')][string]$Body     = '',
  [Parameter(ParameterSetName = 'Write')][string]$BodyFile = '',
  [Parameter(ParameterSetName = 'Write')][string]$Cwd      = '',

  [int]$MaxAgeHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SyncHome   = Join-Path $env:USERPROFILE '.ai-sync'
$HandoffDir = Join-Path $SyncHome 'handoff'
$ActiveFile = Join-Path $HandoffDir 'HANDOFF.md'
$ArchiveDir = Join-Path $HandoffDir 'archive'

function Write-Utf8NoBom {
  param([string]$Path, [string]$Text)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# The active note is frontmatter + body; parse just enough to report origin and age.
function Read-Active {
  if (-not (Test-Path -LiteralPath $ActiveFile)) { return $null }
  $raw  = [System.IO.File]::ReadAllText($ActiveFile)
  $meta = @{ from = 'unknown'; title = ''; written = ''; cwd = '' }
  if ($raw -match '(?s)^\s*---\r?\n(.*?)\r?\n---\r?\n?') {
    foreach ($line in ($matches[1] -split '\r?\n')) {
      if ($line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$') { $meta[$matches[1]] = $matches[2].Trim() }
    }
  }
  $written = (Get-Item -LiteralPath $ActiveFile).LastWriteTime
  if ($meta['written']) { try { $written = [datetime]::Parse($meta['written']) } catch { } }
  return [pscustomobject]@{
    Raw      = $raw
    From     = $meta['from']
    Title    = $meta['title']
    Cwd      = $meta['cwd']
    Written  = $written
    AgeHours = ((Get-Date) - $written).TotalHours
  }
}

function Move-ToArchive {
  param($Active, [string]$Reason)
  if (-not $Active) { return $null }
  $safeFrom = ($Active.From -replace '[^A-Za-z0-9_-]', '')
  if (-not $safeFrom) { $safeFrom = 'unknown' }
  $dest = Join-Path $ArchiveDir ('{0}-{1}.md' -f $Active.Written.ToString('yyyyMMdd-HHmmss'), $safeFrom)
  New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
  $text = $Active.Raw
  if ($Reason) { $text = "<!-- archived: $Reason ($(Get-Date -Format s)) -->`n" + $text }
  [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
  Remove-Item -LiteralPath $ActiveFile -Force
  return $dest
}

switch ($PSCmdlet.ParameterSetName) {

  'Write' {
    $text = ''
    if ($BodyFile) {
      if (-not (Test-Path -LiteralPath $BodyFile)) { throw "BodyFile not found: $BodyFile" }
      $text = [System.IO.File]::ReadAllText($BodyFile)
    }
    elseif ($Body) { $text = $Body }
    if (-not $text.Trim()) { throw 'Handoff body is empty. Pass -Body or -BodyFile.' }

    if (-not $From) {
      # Best-effort origin so a note still labels itself when the caller forgets -From.
      if     ($env:CLAUDE_CODE_TMPDIR) { $From = 'claude' }
      elseif ($env:CODEX_HOME)         { $From = 'codex'  }
      elseif ($env:CURSOR_TRACE_ID)    { $From = 'cursor' }
      else                             { $From = 'unknown' }
    }
    if (-not $Cwd)   { $Cwd = (Get-Location).Path }
    if (-not $Title) { $Title = ($text.Trim() -split '\r?\n')[0] }
    $Title = ($Title -replace '[\r\n]', ' ').Trim()
    if ($Title.Length -gt 120) { $Title = $Title.Substring(0, 117) + '...' }

    $prev = Read-Active
    if ($prev) { Move-ToArchive $prev 'superseded by a newer handoff' | Out-Null }

    $fm = @(
      '---'
      "from: $From"
      "written: $((Get-Date).ToString('o'))"
      "title: $Title"
      "cwd: $Cwd"
      '---'
      ''
    ) -join "`n"
    Write-Utf8NoBom $ActiveFile ($fm + $text.TrimEnd() + "`n")
    Write-Host "Handoff written by '$From': $Title"
    Write-Host "  $ActiveFile"
    Write-Host '  The next session in any tool will see it. Clear it with: handoff.ps1 -Clear'
    exit 0
  }

  'Clear' {
    $a = Read-Active
    if (-not $a) { Write-Host 'No active handoff.'; exit 0 }
    $dest = Move-ToArchive $a 'cleared - work complete'
    Write-Host "Handoff cleared (archived to $dest)."
    exit 0
  }

  'Status' {
    $a = Read-Active
    if (-not $a) { Write-Host 'No active handoff.'; exit 1 }
    Write-Host ("Active handoff from '{0}', {1:N1}h old: {2}" -f $a.From, $a.AgeHours, $a.Title)
    exit 0
  }

  default {
    $a = Read-Active
    if (-not $a) { Write-Host 'No active handoff.'; exit 1 }
    if ($a.AgeHours -gt $MaxAgeHours) {
      Write-Host ('(note: {0:N1}h old, past the {1}h freshness window)' -f $a.AgeHours, $MaxAgeHours)
    }
    Write-Output $a.Raw
    exit 0
  }
}

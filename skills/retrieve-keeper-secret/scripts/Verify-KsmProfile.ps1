<#
    Verify-KsmProfile.ps1
    Proves the 'contoso' KSM profile can read every shared record WITHOUT Commander
    and without SSO. Prints length + a short SHA-256 prefix only - never a value.

    The profile flag is -p / --profile-name. There is no --profile.
#>
[CmdletBinding()]
param([string]$ProfileName = 'contoso')

$ErrorActionPreference = 'Continue'
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
function ksm { & py -m keeper_secrets_manager_cli @args }

$Records = [ordered]@{
    'Freshservice API'   = 'KEEPERUID00000000000B'
    'Rapid7 InsightVM'   = 'ekhfX2K9Gf6M6L0vCcfh7A'
    'Automox API'        = '7rOFNUuckyxKAAs2MVhWfQ'
    'ScreenConnect API'  = 'KEEPERUID00000000000C'
    'FedEx Bot'          = 'KEEPERUID000000000007'
    'HVE OAuth app'      = 'Di4PRk_xQ6aSo6FTJHw2ww'
    'HVE NoReply passwd' = 'CvQxf7-sVY-zG9-ocTNqlw'
}

function Get-Fingerprint([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    return [BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 12)
}

Write-Host '=== profiles ==='
ksm profile list 2>&1 | Select-Object -First 10

Write-Host ''
Write-Host '=== secrets visible to the app ==='
ksm -p $ProfileName secret list 2>&1 | Select-Object -First 25

# An absent-but-declared field returns the JSON literal '[]' - length 2,
# sha256 prefix 4F53CDA18C2B - NOT an error and NOT whitespace. Guarding only on
# IsNullOrWhiteSpace scored two empty sshKeys records as [ok] on 2026-08-04.
function Test-EmptyResult([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    if ($Value -match '^\s*(\[\s*\]|\{\s*\}|""|''''|null)\s*$') { return $true }
    if ($Value -match 'Error|Traceback|Usage:') { return $true }

    # Structured fields can be non-empty JSON while carrying no usable value.
    # Example observed 2026-08-06: {"privateKey":"\n"} was incorrectly
    # accepted as a 20-character ScreenConnect secret.
    try {
        $parsed = $Value | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [pscustomobject]) {
            $usable = @($parsed.PSObject.Properties.Value | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
            if ($usable.Count -eq 0) { return $true }
        }
    }
    catch {
        # Plain strings are valid candidate values; only structured JSON needs
        # the additional empty-value check above.
    }
    return $false
}

function Get-SdkNotesProof([string]$Uid, [string]$KsmProfileName) {
    # The CLI's JMESPath notes query regressed for one sshKeys record on
    # 2026-08-06. The SDK still decrypted record.dict['notes']; return only a
    # length + SHA proof so this verification script never prints the value.
    try {
        $proofScript = Join-Path $PSScriptRoot 'Get-KsmNotesProof.py'
        $proof = (& py $proofScript '--profile' $KsmProfileName '--uid' $Uid 2>$null | Out-String).Trim() | ConvertFrom-Json -ErrorAction Stop
        if ([int]$proof.length -gt 0) { return $proof }
    }
    catch { }
    return $null
}

Write-Host ''
Write-Host '=== per-record read proof (no values printed) ==='
foreach ($k in $Records.Keys) {
    $uid = $Records[$k]
    $hit = $null

    # Candidates in order. 'notes' is a top-level record property in KSM, not an
    # entry in fields[], so --field notes always returns []; it needs -q notes.
    # sshKeys records here declare an empty password field and park the real
    # connection profile in notes.
    $candidates = @(
        @{ Label = 'password'; Args = @('--field', 'password') },
        @{ Label = 'notes';    Args = @('-q', 'notes', '--raw') },
        @{ Label = 'keyPair';  Args = @('--field', 'keyPair') }
    )

    foreach ($c in $candidates) {
        $out = (ksm -p $ProfileName secret get --uid $uid @($c.Args) 2>&1 | Out-String).Trim()
        if (-not (Test-EmptyResult $out)) {
            $hit = [pscustomobject]@{ Field = $c.Label; Len = $out.Length; Sha = (Get-Fingerprint $out) }
            Remove-Variable out -ErrorAction SilentlyContinue
            break
        }

        if ($c.Label -eq 'notes') {
            $sdkProof = Get-SdkNotesProof -Uid $uid -KsmProfileName $ProfileName
            if ($sdkProof) {
                $hit = [pscustomobject]@{ Field = 'notes-sdk'; Len = [int]$sdkProof.length; Sha = [string]$sdkProof.sha }
                Remove-Variable out, sdkProof -ErrorAction SilentlyContinue
                break
            }
        }
        Remove-Variable out -ErrorAction SilentlyContinue
    }

    if ($hit) {
        Write-Host ("  [ok  ] {0,-20} {1,-9} len={2,-5} sha256={3}" -f $k, $hit.Field, $hit.Len, $hit.Sha)
    } else {
        Write-Host ("  [FAIL] {0,-20} nothing readable in password/notes/keyPair" -f $k)
    }
}

Write-Host ''
Write-Host 'If every row is [ok], KSM has fully replaced the SSO-bound Commander path for reads.'

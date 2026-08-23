<#
    Build-KsmProfile.ps1
    One-shot build of a durable, non-SSO Keeper Secrets Manager credential.

    Run this ONCE while an interactive Commander session is live. Everything after
    that point uses the KSM device keypair, which does not expire and never touches SSO.

    Nothing secret is ever printed: the one-time token is captured in-process and
    redeemed immediately.
#>
[CmdletBinding()]
param(
    [string]$AppName     = 'Contoso Automation',
    [string]$ClientName  = 'euc-workstation',
    [string]$ProfileName = 'contoso',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
$keeper = 'C:\Program Files (x86)\Keeper Commander\keeper-commander.exe'
function ksm { & py -m keeper_secrets_manager_cli @args }

# Records the automation actually needs. Read-only.
$Records = [ordered]@{
    'Freshservice API'   = 'KEEPERUID00000000000B'
    'Rapid7 InsightVM'   = 'ekhfX2K9Gf6M6L0vCcfh7A'
    'Automox API'        = '7rOFNUuckyxKAAs2MVhWfQ'
    'ScreenConnect API'  = 'KEEPERUID00000000000C'
    'FedEx Bot'          = 'KEEPERUID000000000007'
    'HVE OAuth app'      = 'Di4PRk_xQ6aSo6FTJHw2ww'
    'HVE NoReply passwd' = 'CvQxf7-sVY-zG9-ocTNqlw'
}

Write-Host '=== 0. session check ==='
$status = (& $keeper login-status 2>&1 | Out-String)
if ($status -notmatch 'Logged in') {
    Write-Host 'Commander is NOT logged in. Run "keeper shell" first and leave it open.'
    exit 2
}
Write-Host '  Logged in.'

Write-Host ''
Write-Host '=== 1. existing Secrets Manager applications ==='
# NOTE: 'app list' is NOT a permission test. On 2026-08-04 it returned a clean
# empty list ("No Applications to list") while the role still denied Secrets
# Manager outright. Only 'app create' in step 2 proves the entitlement.
$apps = (& $keeper secrets-manager app list 2>&1 | Out-String)
Write-Host ($apps.Trim() -split "`n" | Select-Object -First 12)

if ($WhatIfOnly) { Write-Host ''; Write-Host 'WhatIf: stopping before any write.'; exit 0 }

Write-Host ''
Write-Host "=== 2. create KSM application '$AppName' ==="
# This is the real entitlement gate. Hard-fail here: on 2026-08-04 a denial here
# cascaded into 7 pointless 'share add' failures and then an API throttle that
# killed the client-add step for a minute.
if ($apps -match [regex]::Escape($AppName)) {
    Write-Host '  already exists, reusing'
} else {
    $created = (& $keeper secrets-manager app create $AppName 2>&1 | Out-String)
    Write-Host (($created.Trim() -split "`n" | Select-Object -First 6) -join "`n")
    if ($created -match 'not permitted|Permission denied|not (allowed|enabled)|unauthorized|Access denied') {
        Write-Host ''
        Write-Host '  -> Secrets Manager is still NOT enabled on this user''s Keeper roles.'
        Write-Host '     Fix in Admin Console > Roles > (role) > Enforcement Policies >'
        Write-Host '     Secrets Manager, then re-run. STOPPING before any further calls.'
        exit 3
    }
}

Write-Host ''
Write-Host '=== 3. share records to the app (EDITABLE - automation can write) ==='
foreach ($k in $Records.Keys) {
    $uid = $Records[$k]
    $out = (& $keeper secrets-manager share add --app $AppName --secret $uid --editable 2>&1 | Out-String).Trim()
    $ok = if ($out -match 'error|denied|not found|Traceback') { 'FAIL' } else { 'ok  ' }
    Write-Host ("  [{0}] {1,-20} {2}" -f $ok, $k, $uid)
    if ($ok -eq 'FAIL') { Write-Host "        $($out -split "`n" | Select-Object -First 2)" }
}

Write-Host ''
Write-Host '=== 4. create client device (IP-UNLOCKED - Cato egress moves) ==='
# --unlock-ip matters here: by default the token binds to the first IP that redeems it,
# and Cato hands out different egress addresses. IP-locking would recreate the current problem.
$clientOut = (& $keeper secrets-manager client add --app $AppName --name $ClientName --unlock-ip 2>&1 | Out-String)

# Keeper throttles after repeated attempts and asks for a 1-minute cooldown.
# Observed 2026-08-04 as the last failure of the run - retry rather than lose the app.
$attempt = 1
while ($clientOut -match 'throttled' -and $attempt -le 3) {
    Write-Host "  throttled by Keeper, waiting 70s (retry $attempt/3)"
    Start-Sleep -Seconds 70
    $clientOut = (& $keeper secrets-manager client add --app $AppName --name $ClientName --unlock-ip 2>&1 | Out-String)
    $attempt++
}

# One-time token looks like  US:XXXXXXXX...  - capture, never print.
$token = $null
foreach ($line in ($clientOut -split "`r?`n")) {
    if ($line -match '\b([A-Z]{2}:[A-Za-z0-9_\-]{20,})\b') { $token = $Matches[1]; break }
    if ($line -match '\b([A-Za-z0-9_\-]{60,})\b')          { $token = $Matches[1]; break }
}
if (-not $token) {
    Write-Host '  Could not parse a one-time token from client add. Raw (token-shaped strings masked):'
    foreach ($l in ($clientOut -split "`r?`n" | Select-Object -First 12)) {
        Write-Host ('    ' + ($l -replace '[A-Za-z0-9_\-]{20,}', '<redacted>'))
    }
    exit 4
}
Write-Host "  one-time token captured (len=$($token.Length), not shown)"

Write-Host ''
Write-Host "=== 5. redeem into ksm profile '$ProfileName' ==="
ksm profile init --profile-name $ProfileName $token 2>&1 | Select-Object -First 8
Remove-Variable token -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=== 6. verify: list secrets WITHOUT Commander ==='
ksm -p $ProfileName secret list 2>&1 | Select-Object -First 20

Write-Host ''
Write-Host '=== 7. proof of a real read (fingerprint only) ==='
$v = (ksm -p $ProfileName secret get --uid 'KEEPERUID00000000000B' --field password 2>&1 | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($v) -or $v -match 'Error|Traceback') {
    Write-Host "  read failed: $(($v -split "`n" | Select-Object -First 2))"
} else {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($v))).Replace('-','')
    Write-Host "  Freshservice API key read OK: len=$($v.Length) sha256=$($h.Substring(0,12))"
}

Write-Host ''
Write-Host 'DONE. From here on, reads use:  py -m keeper_secrets_manager_cli -p contoso secret get ...'
Write-Host 'The profile flag is -p / --profile-name. There is NO --profile.'
Write-Host 'No SSO, no token paste, no expiry. Commander is only needed for vault admin.'

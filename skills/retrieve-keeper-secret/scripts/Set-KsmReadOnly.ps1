<#
    Set-KsmReadOnly.ps1

    Narrows the 'Contoso Automation' KSM app to READ-ONLY on the 7 production
    credential records, then opens a separate EDITABLE shared folder so future
    automations can still create/update records via KSM without holding write
    access to the credentials themselves.

    'share update --readonly' changes the permission in place, so there is no
    window where the app loses read access.

    Needs a live Commander session (vault admin). Prints no secret values.
#>
[CmdletBinding()]
param(
    [string]$AppName      = 'Contoso Automation',
    [string]$WriteFolder  = 'Contoso Automation Writes',
    [string]$ProfileName  = 'contoso'
)

$ErrorActionPreference = 'Continue'
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
$keeper = 'C:\Program Files (x86)\Keeper Commander\keeper-commander.exe'
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

Write-Host '=== 0. session check ==='
$status = (& $keeper login-status 2>&1 | Out-String)
if ($status -notmatch 'Logged in') {
    Write-Host 'Commander is NOT logged in. Run "keeper shell" first and leave it open.'
    exit 2
}
Write-Host '  Logged in.'

Write-Host ''
Write-Host "=== 1. downgrade all 7 records to READ-ONLY on '$AppName' ==="
$failed = 0
foreach ($k in $Records.Keys) {
    $uid = $Records[$k]
    $out = (& $keeper secrets-manager share update --app $AppName --secret $uid --readonly 2>&1 | Out-String).Trim()
    if ($out -match '(?i)error|denied|not found|traceback|failed') {
        Write-Host ("  [FAIL] {0,-20} {1}" -f $k, (($out -split "`n" | Select-Object -First 1)))
        $failed++
    } else {
        Write-Host ("  [ok  ] {0,-20} read-only" -f $k)
    }
}

Write-Host ''
Write-Host "=== 2. create shared folder '$WriteFolder' for automation writes ==="
# No -a/-u/-r/-s/-e: those set defaults for HUMAN members of the folder. The KSM
# app's edit right comes from the --editable share in step 3, not from these.
$mk = (& $keeper mkdir -sf $WriteFolder 2>&1 | Out-String).Trim()
Write-Host ('  ' + (($mk -split "`n" | Select-Object -First 3) -join ' | '))

Write-Host ''
Write-Host "=== 3. share that folder to the app as EDITABLE ==="
# --secret accepts a shared-folder PATH as well as a UID, so no UID parsing.
$sh = (& $keeper secrets-manager share add --app $AppName --secret $WriteFolder --editable 2>&1 | Out-String).Trim()
Write-Host ('  ' + (($sh -split "`n" | Select-Object -First 3) -join ' | '))

Write-Host ''
Write-Host '=== 4. app permission table (source of truth for read-only) ==='
& $keeper secrets-manager app get $AppName 2>&1 | Select-Object -First 40

Write-Host ''
Write-Host '=== 5. what KSM now sees as writable folders ==='
ksm -p $ProfileName folder list 2>&1 | Select-Object -First 10

Write-Host ''
if ($failed -gt 0) { Write-Host "WARNING: $failed record(s) failed to downgrade - check the table above." }
Write-Host 'Next: verify a KSM-side create into the new folder, then delete the test record.'

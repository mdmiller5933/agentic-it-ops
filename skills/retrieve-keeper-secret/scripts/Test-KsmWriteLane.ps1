<#
    Test-KsmWriteLane.ps1

    Two proofs:
      A. The 7 credential records are read-only to the app (via Commander's
         permission table - NOT by attempting a write against a live secret).
      B. KSM can still create, read back, and delete a record inside the
         dedicated 'Contoso Automation Writes' shared folder.

    Note the flag collision: the GLOBAL profile flag is -p and must come BEFORE
    the subcommand, while inside 'secret add field' -p means --password-generate.
#>
[CmdletBinding()]
param(
    [string]$AppName     = 'Contoso Automation',
    [string]$FolderUid   = 'KEEPERUID000000000006',
    [string]$ProfileName = 'contoso',
    [int]$ThrottleWait   = 75
)

$ErrorActionPreference = 'Continue'
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
$keeper = 'C:\Program Files (x86)\Keeper Commander\keeper-commander.exe'
function ksm { & py -m keeper_secrets_manager_cli @args }

Write-Host "=== A. app permission table (waiting ${ThrottleWait}s for the API throttle) ==="
Start-Sleep -Seconds $ThrottleWait
$appGet = (& $keeper secrets-manager app get $AppName 2>&1 | Out-String)
if ($appGet -match 'throttled') {
    Write-Host '  still throttled - re-run this script to see the table'
} else {
    # Titles and permission flags only; no field values are rendered by app get.
    Write-Host ($appGet.Trim() -split "`n" | Select-Object -First 40)
}

Write-Host ''
Write-Host '=== B1. create a throwaway record in the write folder (via KSM only) ==='
$title = 'ZZ KSM write-lane test - safe to delete'
$addOut = (ksm -p $ProfileName secret add field --sf $FolderUid --rt login -t $title -p `
            'login=ksm-write-test' 2>&1 | Out-String).Trim()
Write-Host ('  ' + (($addOut -split "`r?`n" | Select-Object -First 4) -join ' | '))

$newUid = ([regex]::Match($addOut, '([A-Za-z0-9_\-]{22})')).Groups[1].Value
if (-not $newUid) {
    Write-Host '  could not parse a new record UID - STOPPING so nothing is left behind blindly.'
    Write-Host '  Check the folder in the Keeper UI and delete the test record manually.'
    exit 1
}
Write-Host "  new record uid=$newUid"

Write-Host ''
Write-Host '=== B2. read it back through KSM (fingerprint only) ==='
$v = (ksm -p $ProfileName secret get --uid $newUid --field password 2>&1 | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($v) -or $v -match '^\s*(\[\s*\]|\{\s*\}|null)\s*$' -or $v -match 'Error|Traceback') {
    Write-Host "  read-back FAILED: $(($v -split "`n" | Select-Object -First 1))"
} else {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hex = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($v))).Replace('-','')
    Write-Host "  read-back OK: generated password len=$($v.Length) sha256=$($hex.Substring(0,12))"
}
Remove-Variable v -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=== B3. delete the throwaway record ==='
$del = (ksm -p $ProfileName secret delete --uid $newUid 2>&1 | Out-String).Trim()
Write-Host ('  ' + (($del -split "`r?`n" | Select-Object -First 3) -join ' | '))

Write-Host ''
Write-Host '=== B4. confirm the folder is empty again ==='
ksm -p $ProfileName secret list 2>&1 | Select-Object -First 15

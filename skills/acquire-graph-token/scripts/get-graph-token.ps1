# Raw OAuth2 device-code flow against the Microsoft Graph Command Line Tools
# public client (same app Connect-MgGraph uses, already consented). We control
# the polling loop, so no 120s watchdog. Token is written to a file, never printed.
$ErrorActionPreference = "Stop"
$tenant = "80bcfe19-ba5c-bcaf-8f4b-1dadba37a010"
$clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
# Write OUTSIDE the skill folder - skill folders are synced/mirrored and must
# never contain a token, even transiently.
$tokenOut = "$env:TEMP\graph-token.json"

$scopes = @(
  "openid", "profile", "offline_access",
  "https://graph.microsoft.com/User.Read",
  "https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All",
  "https://graph.microsoft.com/DeviceManagementScripts.ReadWrite.All",
  "https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All",
  "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
  "https://graph.microsoft.com/Group.Read.All"
) -join " "

$dc = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode" `
  -Body @{ client_id = $clientId; scope = $scopes }

Write-Host "USER_CODE: $($dc.user_code)"
Write-Host "URL: $($dc.verification_uri)"
Write-Host "Code valid for $($dc.expires_in) seconds. Polling..."
[Console]::Out.Flush()

$deadline = (Get-Date).AddSeconds([Math]::Min($dc.expires_in, 850))
$interval = [Math]::Max([int]$dc.interval, 5)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds $interval
  try {
    $tok = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
      -Body @{
        grant_type = "urn:ietf:params:oauth:grant-type:device_code"
        client_id = $clientId
        device_code = $dc.device_code
      }
    $tok | ConvertTo-Json -Compress | Set-Content -Path $tokenOut
    Write-Host "TOKEN_ACQUIRED (written to file, expires_in=$($tok.expires_in)s)"
    Write-Host "GRANTED_SCOPES: $($tok.scope)"
    exit 0
  } catch {
    $body = $null
    try { $body = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
    if ($body -eq "authorization_pending") { continue }
    if ($body -eq "slow_down") { $interval += 5; continue }
    Write-Host "AUTH_FAILED: $body"
    Write-Host $_.ErrorDetails.Message
    exit 1
  }
}
Write-Host "AUTH_TIMEOUT: code expired without sign-in"
exit 1

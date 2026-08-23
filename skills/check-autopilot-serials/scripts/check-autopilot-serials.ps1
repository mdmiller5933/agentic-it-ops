[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Serials,

    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

if (-not $OutputDir) {
    $OutputDir = Join-Path (Get-Location) 'reports'
}

# App-only tokens carry app ROLES, not delegated scopes, and 'User.Read' exists
# only as a delegated scope - leaving it in the required list makes the app-only
# check unsatisfiable. Get-MgContext.Scopes is populated in both modes.
$requiredDelegatedScopes = @(
    'User.Read',
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementServiceConfig.Read.All'
)
$requiredAppRoles = @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementServiceConfig.Read.All'
)

function Get-AppIdentitySetting {
    <#
        Read one GRAPH_APP_* value, preferring the process block and falling back
        to the User scope. A shell that was started BEFORE the provisioning step
        set these at User scope keeps a stale (empty) process block, so without
        this fallback the app-only branch is skipped silently and the script drops
        to the interactive path that cannot work unattended - the exact quiet
        failure change 10035 is about. Non-Windows returns $null for the User scope,
        which is harmless.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        try { $value = [Environment]::GetEnvironmentVariable($Name, 'User') } catch { $value = $null }
    }
    return $value
}

# App-only identity (survives the nightly z-account rotation). Set by the
# provisioning step; empty means the cert path is not configured yet.
$appTenantId   = Get-AppIdentitySetting -Name 'GRAPH_APP_TENANT_ID'
$appClientId   = Get-AppIdentitySetting -Name 'GRAPH_APP_CLIENT_ID'
$appThumbprint = Get-AppIdentitySetting -Name 'GRAPH_APP_CERT_THUMBPRINT'

function Test-GraphScope {
    param(
        [object]$Context,
        [string[]]$RequiredScopes
    )

    if (-not $Context -or -not $Context.Account) {
        return $false
    }

    $granted = @($Context.Scopes | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($scope in $RequiredScopes) {
        if ($granted -notcontains $scope.ToLowerInvariant()) {
            return $false
        }
    }

    return $true
}

function ConvertTo-ODataLiteral {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function Convert-GraphValue {
    param([object]$Value)

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString('o')
    }

    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime.ToString('o')
    }

    if ($Value -is [string] -and $Value -match '^/Date\((-?\d+)\)/$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Matches[1]).UtcDateTime.ToString('o')
    }

    return $Value
}

function Invoke-GraphGet {
    param([string]$Uri)

    Invoke-MgGraphRequest `
        -Method GET `
        -Uri $Uri `
        -OutputType PSObject `
        -ErrorAction Stop
}

function Get-GraphCollection {
    param([string]$Uri)

    $items = @()
    $next = $Uri

    while ($next) {
        $response = Invoke-GraphGet -Uri $next
        foreach ($item in @($response.value)) {
            $items += $item
        }
        $next = $response.'@odata.nextLink'
    }

    return @($items)
}

function Select-Fields {
    param(
        [object]$Item,
        [string[]]$Fields
    )

    if (-not $Item) {
        return $null
    }

    $out = [ordered]@{}
    foreach ($field in $Fields) {
        $out[$field] = Convert-GraphValue -Value $Item.$field
    }

    return [pscustomobject]$out
}

$usingAppOnly = -not ([string]::IsNullOrWhiteSpace($appTenantId) -or
                      [string]::IsNullOrWhiteSpace($appClientId) -or
                      [string]::IsNullOrWhiteSpace($appThumbprint))

$context = Get-MgContext
if ($usingAppOnly) {
    if (-not $context -or $context.AuthType -ne 'AppOnly' -or $context.ClientId -ne $appClientId) {
        $thumb = ($appThumbprint -replace '\s', '').ToUpperInvariant()
        $cert = Get-ChildItem -Path 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumb -and $_.HasPrivateKey } |
            Select-Object -First 1
        if (-not $cert) {
            throw "GRAPH_PREFLIGHT_FAIL: app-only certificate $thumb not found with a private key in CurrentUser\My or LocalMachine\My."
        }
        Connect-MgGraph -NoWelcome -TenantId $appTenantId -ClientId $appClientId -Certificate $cert | Out-Null
        $context = Get-MgContext
    }
    if (-not $context -or $context.AuthType -ne 'AppOnly') {
        throw 'GRAPH_PREFLIGHT_FAIL: expected an app-only Graph context and did not get one.'
    }
    # Deliberately NOT Test-GraphScope: it requires $Context.Account, which is
    # always empty for app-only (Learn: microsoftgraph/app-only sample output).
    $grantedRoles = @($context.Scopes)
    $missingRoles = @($requiredAppRoles | Where-Object { $grantedRoles -notcontains $_ })
    if ($missingRoles.Count -gt 0) {
        throw ("GRAPH_PREFLIGHT_FAIL: app {0} is missing role(s): {1}. Granted: {2}." -f
               $appClientId, ($missingRoles -join ', '), ($grantedRoles -join ', '))
    }
    Write-Host ("GRAPH_PREFLIGHT_OK kind=app appid={0} tenant={1}" -f $context.ClientId, $context.TenantId)
}
else {
    # KEEP the interactive/MSAL connect as the LAST RESORT. Replacing it with a bare
    # throw would be a regression: -ContextScope CurrentUser reuses the on-disk MSAL
    # cache, Get-MgContext returns $null in every fresh process, and with the three
    # GRAPH_APP_* variables unset the script could not authenticate at all - for a
    # human in a normal shell as much as for the agent.
    if (-not (Test-GraphScope -Context $context -RequiredScopes $requiredDelegatedScopes)) {
        Connect-MgGraph -NoWelcome -ContextScope CurrentUser -Scopes $requiredDelegatedScopes | Out-Null
        $context = Get-MgContext
    }
    if (-not (Test-GraphScope -Context $context -RequiredScopes $requiredDelegatedScopes)) {
        # Now it is genuinely unusable. Interactive Connect-MgGraph is a documented dead
        # end from the AGENT shell ("A window handle must be configured"), so say what to
        # do rather than dying on a misleading WAM error.
        throw ("GRAPH_PREFLIGHT_FAIL: no app-only certificate configured " +
               "(GRAPH_APP_TENANT_ID / GRAPH_APP_CLIENT_ID / GRAPH_APP_CERT_THUMBPRINT) and no usable " +
               "delegated context. Run 'C:\automox-mcp-main\scripts\graph-auth\graph-token.cmd' in an " +
               "interactive session, or provision the certificate.")
    }
    Write-Host ("GRAPH_PREFLIGHT_OK kind=delegated account={0}" -f $context.Account)
}

# $context.Account is EMPTY under app-only, so anything downstream that keys off the
# report's "account" field would silently get "". Fall back to the app id.
$reportPrincipal = if (-not [string]::IsNullOrWhiteSpace($context.Account)) {
    $context.Account
} else {
    "appid:$($context.ClientId)"
}

$normalizedSerials = @(
    $Serials |
        ForEach-Object { $_ -split '[,;\s]+' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Select-Object -Unique
)

if ($normalizedSerials.Count -eq 0) {
    throw 'No serial numbers were provided.'
}

$autopilotFields = @(
    'id',
    'serialNumber',
    'manufacturer',
    'model',
    'groupTag',
    'purchaseOrderIdentifier',
    'enrollmentState',
    'lastContactedDateTime',
    'deploymentProfileAssignmentStatus',
    'deploymentProfileAssignmentDetailedStatus',
    'deploymentProfileAssignedDateTime',
    'azureActiveDirectoryDeviceId',
    'managedDeviceId',
    'userPrincipalName',
    'addressableUserName'
)

$managedDeviceFields = @(
    'id',
    'deviceName',
    'serialNumber',
    'azureADDeviceId',
    'userPrincipalName',
    'managedDeviceOwnerType',
    'operatingSystem',
    'complianceState',
    'managementAgent',
    'enrolledDateTime',
    'lastSyncDateTime'
)

$allAutopilotDevices = @(
    Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$top=100"
)

$results = foreach ($serial in $normalizedSerials) {
    $literal = ConvertTo-ODataLiteral -Value $serial
    $encodedManagedFilter = [System.Uri]::EscapeDataString("serialNumber eq '$literal'")
    $managedUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$encodedManagedFilter&`$top=25"

    $autopilotMatches = @(
        $allAutopilotDevices |
            Where-Object { $_.serialNumber -and $_.serialNumber.Trim().ToUpperInvariant() -eq $serial }
    )
    $managedMatches = @(Get-GraphCollection -Uri $managedUri)

    [pscustomobject]@{
        serialNumber       = $serial
        autopilotEnrolled  = ($autopilotMatches.Count -gt 0)
        autopilotMatches   = @($autopilotMatches | ForEach-Object { Select-Fields -Item $_ -Fields $autopilotFields })
        intuneManaged      = ($managedMatches.Count -gt 0)
        managedDeviceCount = $managedMatches.Count
        managedDevices     = @($managedMatches | ForEach-Object { Select-Fields -Item $_ -Fields $managedDeviceFields })
    }
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ')
$jsonPath = Join-Path $OutputDir "autopilot-serial-check-$stamp.json"

$report = [pscustomobject]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    account        = $reportPrincipal
    tenantId       = $context.TenantId
    source         = 'Microsoft Graph beta deviceManagement/windowsAutopilotDeviceIdentities and managedDevices'
    serials        = $normalizedSerials
    results        = @($results)
}

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

[pscustomobject]@{
    generatedAtUtc = $report.generatedAtUtc
    account        = $report.account
    tenantId       = $report.tenantId
    jsonPath       = $jsonPath
    results        = @($results | ForEach-Object {
        $autopilot = if ($_.autopilotMatches.Count -gt 0) { $_.autopilotMatches[0] } else { $null }
        $managed = if ($_.managedDevices.Count -gt 0) { $_.managedDevices[0] } else { $null }

        [pscustomobject]@{
            serialNumber                      = $_.serialNumber
            autopilotEnrolled                 = $_.autopilotEnrolled
            enrollmentState                   = if ($autopilot) { $autopilot.enrollmentState } else { $null }
            groupTag                          = if ($autopilot) { $autopilot.groupTag } else { $null }
            manufacturer                      = if ($autopilot) { $autopilot.manufacturer } else { $null }
            model                             = if ($autopilot) { $autopilot.model } else { $null }
            deploymentProfileAssignmentStatus = if ($autopilot) { $autopilot.deploymentProfileAssignmentStatus } else { $null }
            autopilotIdentityId               = if ($autopilot) { $autopilot.id } else { $null }
            intuneManaged                     = $_.intuneManaged
            managedDeviceName                 = if ($managed) { $managed.deviceName } else { $null }
            managedDeviceId                   = if ($managed) { $managed.id } else { $null }
            userPrincipalName                 = if ($managed) { $managed.userPrincipalName } else { $null }
            complianceState                   = if ($managed) { $managed.complianceState } else { $null }
            lastSyncDateTime                  = if ($managed) { $managed.lastSyncDateTime } else { $null }
        }
    })
} | ConvertTo-Json -Depth 10
